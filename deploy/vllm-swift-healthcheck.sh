#!/usr/bin/env bash
# Health watchdog for the vLLM Swift systemd service.
#
# Run periodically by vllm-swift-healthcheck.timer. It probes cheap,
# load-independent signals only:
#
#   * the unit's systemd state
#   * that the KV-offload cache volume is still a mountpoint
#   * GET /health, which returns 200 while the engine has not reported an error
#     and 503 once it has (EngineDeadError). It is a flag check on the API
#     server, not an engine round-trip, so a busy engine does NOT make it fail
#     and it is safe to poll frequently.
#
# After FAIL_THRESHOLD consecutive failures it restarts the unit, subject to a
# restart budget so a persistent fault (for example a stray process holding GPU
# memory) cannot turn into an endless reload loop.
#
# An intentional `systemctl stop vllm-swift` is not fought: an inactive unit
# whose Result is `success` is treated as a deliberate stop.
set -uo pipefail

CONF=${VLLM_HEALTHCHECK_CONF:-/etc/default/vllm-swift-healthcheck}

# The defaults file must supply defaults, not clobber explicit configuration.
# Values supplied through the environment (a systemd Environment=/drop-in, or a
# one-off CLI run) win over the file, so snapshot them before sourcing it.
_CONFIG_VARS=(
  VLLM_UNIT VLLM_HEALTH_URL VLLM_CACHE_MNT VLLM_FAIL_THRESHOLD
  VLLM_CURL_TIMEOUT VLLM_MIN_FREE_BYTES VLLM_RESTART_BUDGET
  VLLM_BUDGET_WINDOW VLLM_MUTE_SECONDS VLLM_STATE_DIR VLLM_DISABLE_FLAG
)
declare -A _env_given=()
for _v in "${_CONFIG_VARS[@]}"; do
  [[ -n ${!_v-} ]] && _env_given[$_v]=${!_v}
done

if [[ -r "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

for _v in "${!_env_given[@]}"; do
  printf -v "$_v" '%s' "${_env_given[$_v]}"
done
unset _v _env_given _CONFIG_VARS

UNIT=${VLLM_UNIT:-vllm-swift.service}
HEALTH_URL=${VLLM_HEALTH_URL:-http://127.0.0.1:8000/health}
CACHE_MNT=${VLLM_CACHE_MNT:-}
STATE_DIR=${VLLM_STATE_DIR:-/run/vllm-swift-healthcheck}
DISABLE_FLAG=${VLLM_DISABLE_FLAG:-/etc/vllm-swift-healthcheck.disabled}

FAIL_THRESHOLD=${VLLM_FAIL_THRESHOLD:-5}
CURL_TIMEOUT=${VLLM_CURL_TIMEOUT:-10}
MIN_FREE_BYTES=${VLLM_MIN_FREE_BYTES:-10737418240}   # 10 GiB, warn only
RESTART_BUDGET=${VLLM_RESTART_BUDGET:-3}             # restarts per window
BUDGET_WINDOW=${VLLM_BUDGET_WINDOW:-3600}            # seconds
MUTE_SECONDS=${VLLM_MUTE_SECONDS:-1800}              # log spacing when muted

log() { printf 'vllm-swift-healthcheck: %s\n' "$*"; }

if [[ -e "$DISABLE_FLAG" ]]; then
  log "disabled via $DISABLE_FLAG; skipping"
  exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
FAIL_FILE="$STATE_DIR/consecutive_failures"
BUDGET_FILE="$STATE_DIR/restarts"
MUTE_FILE="$STATE_DIR/last_mute_log"

failures=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
[[ "$failures" =~ ^[0-9]+$ ]] || failures=0

reset_failures() {
  if (( failures > 0 )); then
    log "recovered after $failures consecutive failure(s)"
  fi
  failures=0
  printf '0\n' >"$FAIL_FILE"
}

# Restart budget: keep only timestamps inside the window.
recent_restarts() {
  local now cutoff
  now=$(date +%s)
  cutoff=$((now - BUDGET_WINDOW))
  [[ -f "$BUDGET_FILE" ]] || return 0
  awk -v c="$cutoff" '$1 >= c' "$BUDGET_FILE" 2>/dev/null
}

record_restart() {
  local now
  now=$(date +%s)
  { recent_restarts; printf '%s\n' "$now"; } >"$BUDGET_FILE.tmp" 2>/dev/null \
    && mv "$BUDGET_FILE.tmp" "$BUDGET_FILE"
}

muted_log() {
  local now last
  now=$(date +%s)
  last=$(cat "$MUTE_FILE" 2>/dev/null || echo 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last >= MUTE_SECONDS )); then
    printf '%s\n' "$now" >"$MUTE_FILE"
    log "$*"
  fi
}

# ---------------------------------------------------------------------------
# Evaluate
# ---------------------------------------------------------------------------
active=$(systemctl is-active "$UNIT" 2>/dev/null || true)
result=$(systemctl show -p Result --value "$UNIT" 2>/dev/null || true)
load_state=$(systemctl show -p LoadState --value "$UNIT" 2>/dev/null || true)
[[ -n "$active" ]] || active=unknown
[[ -n "$result" ]] || result=unknown

# A unit that does not exist would otherwise look like a deliberate stop and be
# ignored forever, which hides a wrong VLLM_UNIT. Fail loudly instead.
if [[ "$load_state" == "not-found" ]]; then
  log "ERROR: unit '$UNIT' is not known to systemd; check VLLM_UNIT in $CONF"
  exit 1
fi

case "$active" in
  activating)
    # systemd is already cycling it (Restart=on-failure); do not pile on.
    log "unit is $active; systemd is handling it, not counting a failure"
    exit 0
    ;;
  inactive)
    if [[ "$result" == "success" ]]; then
      # Deliberate `systemctl stop`, or a unit never started on purpose.
      reset_failures
      log "unit inactive after a clean stop; treating as intentional"
      exit 0
    fi
    fail_reason="unit inactive (Result=$result)"
    ;;
  active)
    fail_reason=""
    if [[ -n "$CACHE_MNT" ]] && ! mountpoint -q "$CACHE_MNT"; then
      fail_reason="KV cache mount is missing: $CACHE_MNT"
    else
      # curl prints 000 and exits non-zero when it cannot connect, so there is
      # deliberately no `|| echo 000` here (that would produce "000000").
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" \
        "$HEALTH_URL" 2>/dev/null)
      code=${code:-000}
      [[ "$code" == "200" ]] || fail_reason="GET $HEALTH_URL returned $code"
    fi
    ;;
  *)
    fail_reason="unit is in unexpected state: $active"
    ;;
esac

# ---------------------------------------------------------------------------
# Act
# ---------------------------------------------------------------------------
if [[ -z "$fail_reason" ]]; then
  reset_failures

  if [[ -n "$CACHE_MNT" ]] && mountpoint -q "$CACHE_MNT"; then
    free_bytes=$(df -B1 --output=avail "$CACHE_MNT" 2>/dev/null | tail -n1 | tr -d ' ')
    if [[ "$free_bytes" =~ ^[0-9]+$ ]] && (( free_bytes < MIN_FREE_BYTES )); then
      log "WARNING: only $((free_bytes / 1024 / 1024)) MiB free on $CACHE_MNT"
    fi
  fi
  exit 0
fi

failures=$((failures + 1))
printf '%s\n' "$failures" >"$FAIL_FILE"
log "FAIL ($failures/$FAIL_THRESHOLD): $fail_reason"

if (( failures < FAIL_THRESHOLD )); then
  exit 0
fi

count=$(recent_restarts | wc -l)
if (( count >= RESTART_BUDGET )); then
  muted_log "not restarting: restart budget exhausted ($count in ${BUDGET_WINDOW}s); investigate manually"
  exit 0
fi

log "restarting $UNIT after $failures consecutive failures (reason: $fail_reason)"
record_restart
failures=0
printf '0\n' >"$FAIL_FILE"

rc=0
if [[ "$active" == "inactive" ]]; then
  systemctl start "$UNIT" || rc=$?
else
  systemctl restart "$UNIT" || rc=$?
fi
if (( rc != 0 )); then
  # The restart attempt still consumed budget and reset the failure counter,
  # so a persistently un-restartable unit backs off instead of looping.
  log "WARNING: systemctl could not restart $UNIT (exit $rc); unit is still unhealthy"
fi
exit 0
