#!/usr/bin/env bash
# Install the vLLM Swift systemd service and health watchdog from this bundle.
#
#   sudo deploy/install.sh \
#     --launch-script /path/to/vllm-kvoffload-launch.sh \
#     --cache-mnt     /path/to/kv-offload-ssd
#
# The served model name (needed for the PID file path) is read from
# <manager-dir>/run-logs/start-manager.state; override with --served-name.
#
# Re-running is safe and idempotent. A running service keeps its previously
# loaded definition until it is restarted; pass --restart to apply immediately.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_MANAGER_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

MANAGER_DIR=$DEFAULT_MANAGER_DIR
LAUNCH_SCRIPT=""
CACHE_MNT=""
RUN_USER=${SUDO_USER:-$(id -un)}
PORT=8000
SERVED_NAME=""
DO_RESTART=0
DO_ENABLE=1

LIBEXEC_DIR=/usr/local/libexec
SYSTEMD_DIR=/etc/systemd/system
DEFAULTS_DIR=/etc/default
DOC_DIR=/usr/local/share/doc/vllm-swift-healthcheck

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  --manager-dir DIR     launcher checkout (default: repository root)
  --launch-script PATH  operator launch script run by the service (required)
  --cache-mnt DIR       KV-offload cache mount point (required)
  --run-user USER       account the service runs as (default: $SUDO_USER)
  --port PORT           API port, used for the health URL (default: 8000)
  --served-name NAME    override the served model name read from the state file
  --no-enable           install files but do not enable units
  --restart             restart vllm-swift.service now to apply the new definition
  -h, --help            show this help

Files written:
  /etc/systemd/system/vllm-swift.service
  /etc/systemd/system/vllm-swift-healthcheck.service
  /etc/systemd/system/vllm-swift-healthcheck.timer
  /etc/default/vllm-swift-healthcheck
  /usr/local/libexec/vllm-swift-healthcheck.sh
  /usr/local/share/doc/vllm-swift-healthcheck/README.md
EOF
}

while (($#)); do
  case "$1" in
    --manager-dir) MANAGER_DIR=${2:?}; shift 2 ;;
    --launch-script) LAUNCH_SCRIPT=${2:?}; shift 2 ;;
    --cache-mnt) CACHE_MNT=${2:?}; shift 2 ;;
    --run-user) RUN_USER=${2:?}; shift 2 ;;
    --port) PORT=${2:?}; shift 2 ;;
    --served-name) SERVED_NAME=${2:?}; shift 2 ;;
    --no-enable) DO_ENABLE=0; shift ;;
    --restart) DO_RESTART=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "install.sh: $*" >&2; exit 1; }

((EUID == 0)) || die "must run as root (use sudo)"
[[ -n "$LAUNCH_SCRIPT" ]] || die "--launch-script is required"
[[ -n "$CACHE_MNT" ]] || die "--cache-mnt is required"
[[ -d "$MANAGER_DIR" ]] || die "manager dir not found: $MANAGER_DIR"
[[ -x "$LAUNCH_SCRIPT" ]] || die "launch script not executable: $LAUNCH_SCRIPT"
[[ -d "$CACHE_MNT" ]] || die "cache mount not found: $CACHE_MNT"
id "$RUN_USER" >/dev/null 2>&1 || die "no such user: $RUN_USER"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be numeric"

STATE_FILE="$MANAGER_DIR/run-logs/start-manager.state"
if [[ -z "$SERVED_NAME" ]]; then
  [[ -r "$STATE_FILE" ]] || die "cannot read $STATE_FILE; pass --served-name"
  SERVED_NAME=$(sed -n 's/^SERVED_NAME=//p' "$STATE_FILE" | head -n1)
  [[ -n "$SERVED_NAME" ]] || die "SERVED_NAME missing in $STATE_FILE; pass --served-name"
fi

PID_FILE="$MANAGER_DIR/run-logs/vllm-${SERVED_NAME}.pid"
RUN_GROUP=$(id -gn "$RUN_USER")
HOME_DIR=$(getent passwd "$RUN_USER" | cut -d: -f6)
[[ -n "$HOME_DIR" ]] || HOME_DIR=/tmp

echo "manager dir   : $MANAGER_DIR"
echo "launch script : $LAUNCH_SCRIPT"
echo "cache mount   : $CACHE_MNT"
echo "run as        : $RUN_USER:$RUN_GROUP"
echo "served name   : $SERVED_NAME"
echo "pid file      : $PID_FILE"
echo

if ! mountpoint -q "$CACHE_MNT"; then
  echo "WARNING: $CACHE_MNT is not currently a mountpoint. The unit declares" >&2
  echo "         RequiresMountsFor=$CACHE_MNT, so add a matching /etc/fstab" >&2
  echo "         entry or the engine will write KV cache onto the root fs." >&2
fi
if [[ ! -e "$PID_FILE" ]]; then
  echo "NOTE: $PID_FILE does not exist yet (normal before the first launch)." >&2
fi

install -d "$SYSTEMD_DIR" "$DEFAULTS_DIR" "$LIBEXEC_DIR" "$DOC_DIR"

# --- service unit (templated) ----------------------------------------------
MANAGER_DIR="$MANAGER_DIR" LAUNCH_SCRIPT="$LAUNCH_SCRIPT" CACHE_MNT="$CACHE_MNT" \
RUN_USER="$RUN_USER" RUN_GROUP="$RUN_GROUP" HOME_DIR="$HOME_DIR" \
SERVED_NAME="$SERVED_NAME" PORT="$PORT" \
python3 - "$SCRIPT_DIR/vllm-swift.service.in" "$SYSTEMD_DIR/vllm-swift.service" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
for key in ("MANAGER_DIR", "LAUNCH_SCRIPT", "CACHE_MNT", "RUN_USER",
            "RUN_GROUP", "HOME_DIR", "SERVED_NAME", "PORT"):
    text = text.replace(f"@{key}@", os.environ[key])
leftover = re.findall(r"@[A-Z_]+@", text)
if leftover:
    sys.exit(f"unsubstituted placeholders in {src}: {sorted(set(leftover))}")
open(dst, "w", encoding="utf-8").write(text)
PY

# --- watchdog ---------------------------------------------------------------
install -m 0755 "$SCRIPT_DIR/vllm-swift-healthcheck.sh" \
  "$LIBEXEC_DIR/vllm-swift-healthcheck.sh"
install -m 0644 "$SCRIPT_DIR/vllm-swift-healthcheck.service" \
  "$SYSTEMD_DIR/vllm-swift-healthcheck.service"
install -m 0644 "$SCRIPT_DIR/vllm-swift-healthcheck.timer" \
  "$SYSTEMD_DIR/vllm-swift-healthcheck.timer"

cat >"$DEFAULTS_DIR/vllm-swift-healthcheck" <<EOF
# Configuration for vllm-swift-healthcheck.sh (see deploy/README.md).
VLLM_UNIT=vllm-swift.service
VLLM_HEALTH_URL=http://127.0.0.1:${PORT}/health
VLLM_CACHE_MNT=${CACHE_MNT}
# VLLM_FAIL_THRESHOLD=5
# VLLM_RESTART_BUDGET=3
# VLLM_MIN_FREE_BYTES=10737418240
EOF
chmod 0644 "$DEFAULTS_DIR/vllm-swift-healthcheck"

if [[ -f "$SCRIPT_DIR/README.md" ]]; then
  install -m 0644 "$SCRIPT_DIR/README.md" "$DOC_DIR/README.md"
fi

systemctl daemon-reload
echo "installed: units written and systemd reloaded"

if ((DO_ENABLE)); then
  systemctl enable vllm-swift.service
  systemctl enable --now vllm-swift-healthcheck.timer
  echo "enabled: vllm-swift.service (boot) and vllm-swift-healthcheck.timer"
fi

if ((DO_RESTART)); then
  systemctl restart vllm-swift.service
  echo "restarted: vllm-swift.service"
else
  if systemctl is-active --quiet vllm-swift.service; then
    echo
    echo "NOTE: vllm-swift.service is running with its previously loaded"
    echo "      definition. Run 'systemctl restart vllm-swift.service' (or"
    echo "      re-run this script with --restart) to apply the new one."
  fi
fi

echo
echo "Verify with:"
echo "  systemctl status vllm-swift-healthcheck.timer"
echo "  /usr/local/libexec/vllm-swift-healthcheck.sh; echo exit=\$?"
echo "  journalctl -u vllm-swift-healthcheck -n 20"
