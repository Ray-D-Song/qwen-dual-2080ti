# systemd Deployment Bundle

Reference systemd units for running a Definitive Edition route as a supervised
service, plus a health watchdog. Install with `deploy/install.sh`; nothing here
is specific to one machine beyond the paths you pass in.

## Why a unit instead of launching from a shell

`launcher.sh` detaches with `nohup setsid`, which survives a closing terminal
but **not** the teardown of the systemd cgroup it was started in. A model
launched from an interactive shell owned by another service is SIGKILLed the
moment that service restarts, with no traceback in the vLLM log. Running it as
its own unit gives it its own cgroup, `Restart=on-failure`, and boot autostart.

## Contents

| File | Purpose |
| --- | --- |
| `vllm-swift.service.in` | Service template; `install.sh` substitutes paths, user, port and served model name. |
| `vllm-swift-healthcheck.sh` | The watchdog probe. |
| `vllm-swift-healthcheck.service` | Oneshot unit that runs the probe. |
| `vllm-swift-healthcheck.timer` | Triggers the probe 5 min after boot, then every 2 min. |
| `install.sh` | Installs and enables everything. |

## Install

```bash
sudo deploy/install.sh \
  --launch-script /path/to/vllm-kvoffload-launch.sh \
  --cache-mnt     /path/to/kv-offload-ssd
```

`--manager-dir` defaults to the repository root. The served model name, needed
for the PID file path, is read from `<manager-dir>/run-logs/start-manager.state`.
Add `--restart` to apply the new definition to an already-running service;
otherwise it keeps its previously loaded one until the next restart.

The cache mount must be in `/etc/fstab` (with `nofail`) so
`RequiresMountsFor=` can order the engine behind it after a reboot. See the
[KV cache offload and tiering guide](../docs/kv-offload-tiering.md).

## What the watchdog detects

| Signal | Detected |
| --- | --- |
| API server process gone / unit failed | yes |
| `GET /health` returning 503 (engine reported dead) | yes |
| Cache volume unmounted | yes |
| Cache volume low on free space | logs a warning only |
| Engine wedged but still reporting healthy | **no** |

`/health` is a flag check on the API server rather than an engine round-trip,
so it stays responsive while the model is busy and will not produce false
failures under load. The trade-off is that a wedged engine which has not marked
itself errored is not detected.

After 5 consecutive failures the watchdog restarts the unit, subject to a
budget of 3 restarts per hour. A restart that itself fails still consumes
budget, so a persistently un-restartable service backs off instead of looping.
A deliberate `systemctl stop` is not fought: an inactive unit whose `Result` is
`success` is treated as intentional.

## Configuration

Edit `/etc/default/vllm-swift-healthcheck`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `VLLM_UNIT` | `vllm-swift.service` | Unit to watch. |
| `VLLM_HEALTH_URL` | `http://127.0.0.1:<port>/health` | Probe URL. |
| `VLLM_CACHE_MNT` | value from `--cache-mnt` | Mount checked for presence and free space. |
| `VLLM_FAIL_THRESHOLD` | `5` | Consecutive failures before restarting. |
| `VLLM_RESTART_BUDGET` | `3` | Restarts allowed per window. |
| `VLLM_BUDGET_WINDOW` | `3600` | Budget window in seconds. |
| `VLLM_MIN_FREE_BYTES` | `10737418240` | Free-space warning threshold (10 GiB). |
| `VLLM_DISABLE_FLAG` | `/etc/vllm-swift-healthcheck.disabled` | If this file exists the watchdog does nothing. |

Values supplied through the environment take precedence over this file, so a
systemd drop-in (`Environment=VLLM_FAIL_THRESHOLD=2`) or a one-off CLI run can
override it without editing the file. The file supplies defaults only.

If `VLLM_UNIT` names a unit systemd does not know about, the probe exits
non-zero with an explicit `ERROR:` line rather than silently doing nothing.

To pause supervision without stopping the model, create the disable flag:

```bash
sudo touch /etc/vllm-swift-healthcheck.disabled   # pause
sudo rm /etc/vllm-swift-healthcheck.disabled      # resume
```

To stop the service for maintenance without the watchdog restarting it, a plain
`sudo systemctl stop vllm-swift` is already sufficient; the stop is recognised
as intentional. Use the flag when you want the probe to skip entirely.

## Inspecting

```bash
systemctl status vllm-swift.service
systemctl status vllm-swift-healthcheck.timer
systemctl list-timers vllm-swift-healthcheck.timer
/usr/local/libexec/vllm-swift-healthcheck.sh; echo "exit=$?"   # run a probe now
journalctl -u vllm-swift-healthcheck -n 50
```

Probe lines are prefixed `vllm-swift-healthcheck:`. A healthy poll is silent;
a failing one logs `FAIL (n/5): <reason>`, a recovery logs `recovered after
<n> consecutive failure(s)`.

## Uninstall

```bash
sudo systemctl disable --now vllm-swift-healthcheck.timer
sudo systemctl disable --now vllm-swift.service
sudo rm -f /etc/systemd/system/vllm-swift{,-healthcheck}.service \
           /etc/systemd/system/vllm-swift-healthcheck.timer \
           /etc/default/vllm-swift-healthcheck \
           /usr/local/libexec/vllm-swift-healthcheck.sh \
           /etc/vllm-swift-healthcheck.disabled
sudo systemctl daemon-reload
```
