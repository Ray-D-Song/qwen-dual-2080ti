# KV Cache Offload And Tiering

`TieringOffloadingSpec` offloads KV cache blocks that no longer fit in GPU
memory, so a repeated prefix can be reused instead of recomputed. It has two
tiers:

| Tier | Medium | Role |
| --- | --- | --- |
| Primary | CPU (`/dev/shm` mmap) | **Mandatory staging gateway**. Every GPU↔offload byte passes through it. Sized by `cpu_bytes_to_use`. |
| Secondary | `fs` (filesystem) | The cache proper. Holds blocks indefinitely unless an eviction budget is configured. |

## The CPU primary tier cannot be removed

Secondary tiers have no direct access to GPU memory, so the CPU primary tier is
the only path in and out. `cpu_bytes_to_use` is a required field and the
primary tier is a required constructor argument. To make the disk the cache and
the CPU tier nothing but a staging buffer, **shrink** `cpu_bytes_to_use` rather
than trying to remove it.

Shrinking it is safe for an existing cache: the cache directory name is a hash
of the block geometry (`blocks_per_file`, `dtype`, `kv_cache_groups`,
parallelism), and `cpu_bytes_to_use` does not participate. Changing
`blocks_per_chunk` / `block_size` / `dtype` **does** change it, which starts a
fresh namespace and orphans the old directory (delete it manually).

`cpu_bytes_to_use` must cover at least one chunk, otherwise the shared region
cannot be mmap'd; the launcher now rejects that with an explicit error.

## Enabling it

The Definitive Edition `launcher.sh` reads `KV_TRANSFER_CONFIG` and appends it
as `--kv-transfer-config`. That environment variable is the whole
configuration:

```json
{
  "kv_connector": "OffloadingConnector",
  "kv_role": "kv_both",
  "kv_load_failure_policy": "recompute",
  "kv_connector_extra_config": {
    "spec_name": "TieringOffloadingSpec",
    "cpu_bytes_to_use": 2147483648,
    "eviction_policy": "lru",
    "secondary_tiers": [
      {
        "type": "fs",
        "root_dir": "/mnt/kv-offload-ssd",
        "n_read_threads": 16,
        "n_write_threads": 16,
        "eviction_policy": "fifo",
        "max_bytes": 300647710720,
        "min_free_bytes": 8589934592,
        "min_file_age_seconds": 10,
        "evict_interval_seconds": 5
      }
    ]
  }
}
```

`kv_role` must be `kv_both` to store and load. With
`kv_load_failure_policy: recompute`, a block that cannot be read back (for
example because FIFO evicted it between the lookup and the load) is recomputed
instead of failing the request.

## Parameters

Top level (`kv_connector_extra_config`):

| Key | Required | Meaning |
| --- | --- | --- |
| `spec_name` | yes | `TieringOffloadingSpec` |
| `cpu_bytes_to_use` | yes | Bytes for the CPU staging tier. Must be ≥ one chunk. |
| `eviction_policy` | no | **Primary (CPU)** tier policy: `lru` (default) or `arc`. |
| `blocks_per_chunk` | no | Blocks coalesced into one chunk. Default `1`. Changes the cache namespace. |
| `block_size` | no | Chunk size in tokens; must be a multiple of the GPU block size. Mutually exclusive with `blocks_per_chunk`. |
| `secondary_tiers` | no | List of secondary tiers. |

`fs` tier:

| Key | Default | Meaning |
| --- | --- | --- |
| `root_dir` | — | Cache root. `max_bytes` is measured against this tier's own subdirectory under it, not the whole root. |
| `n_read_threads` / `n_write_threads` | `16` | I/O thread counts. |
| `eviction_policy` | `fifo` | Only `fifo` is supported. **Not** the same setting as the top-level one, which governs the CPU tier. |
| `max_bytes` | unset | Byte budget for this tier. Unset means blocks are kept forever (legacy behaviour). |
| `min_free_bytes` | unset | `statvfs` free-space floor on the host filesystem; eviction also runs below it. ENOSPC safety net. |
| `min_file_age_seconds` | `10` | Blocks younger than this are never evicted, so a block being promoted is not removed from under its reader. |
| `evict_interval_seconds` | `5` | Background evictor wake-up period. |
| `enable_kv_events` / `locality` | — | KV-event emission and LOCAL/REMOTE labelling. |

## FIFO eviction

Eviction removes the **oldest-written** blocks first. Ordering comes from the
block file's `mtime`, which is exact here: block files are content-addressed,
written once through `os.replace`, and never rewritten, so `mtime` is the
insertion time. This also keeps the policy correct across restarts and when
several instances share one `root_dir`.

Eviction runs on its own daemon thread and never occupies the transfer thread
pool. With no budget configured the tier behaves exactly as before.

## Capacity sizing

`max_bytes` must stay comfortably under the filesystem's usable data area.
Check what is actually available:

```bash
df -h /mnt/kv-offload-ssd                 # usable size, used, available
sudo tune2fs -l /dev/loopN | grep -i reserved   # reserved block percentage
```

ext4 metadata means the mount is smaller than the image, and reserved blocks
are withheld from unprivileged users unless the filesystem was created with
`-m 0`. Budget against the *reported* size and leave headroom for the tier's
`config.json` files and any other content on the volume.

Reference deployment (dual RTX 2080 Ti, 300 GiB image):

| Quantity | Value |
| --- | --- |
| Image / usable ext4 | 300 GiB / 294.2 GiB (`reserved=0%`) |
| `cpu_bytes_to_use` | `2147483648` (2 GiB) → 38 chunks, `/dev/shm` region 2.14 GB |
| `max_bytes` | `300647710720` (280 GiB), ~14 GiB headroom |
| `min_free_bytes` | `8589934592` (8 GiB) |
| Measured | 48 eviction passes under real traffic, settling exactly at budget; 0 allocation failures |

## What happens when the volume fills

With no budget configured, a full volume does **not** crash the engine: each
store fails per block, the worker logs
`Job <id> block I/O failed: [Errno 28] No space left on device`, the block is
simply not cached, and serving continues. The directory never shrinks on its
own, so the disk tier silently stops contributing. Configuring `max_bytes`
is what turns that into a bounded, self-managing cache.

## Operational notes

- **`/dev/shm` is a startup precondition.** The staging region is sized from
  `cpu_bytes_to_use` and the engine refuses to start if the tmpfs cannot hold
  it. An 8 GiB staging tier needs 8 GiB free in `/dev/shm`.
- **Clean up stale regions.** The scheduler-side mmap
  (`/dev/shm/vllm_offload_<engine_id>.mmap`) is not unlinked on shutdown, so a
  killed instance leaves it behind. Remove it before starting a new instance,
  but only when no vLLM process is running.
- **Stores can be dropped silently when the staging tier is too small.**
  `prepare_store` returns `None` when it cannot free enough chunks; the
  connector counts an allocation failure and skips that block. The launcher
  logs a throttled warning for it. If it appears under normal traffic, raise
  `cpu_bytes_to_use`.

## Operator script sample

Save as `vllm-kvoffload-launch.sh` next to `launcher.sh`; adjust the four
variables at the top. This mirrors the validated deployment.

```bash
#!/usr/bin/env bash
# Start the saved launcher route with CPU staging + SSD KV cache and FIFO eviction.
set -euo pipefail

MANAGER=/path/to/vLLM-2080Ti-Definitive        # the launcher checkout
MODEL_CACHE_IMG=/path/to/kv-offload-ssd.img    # sparse image backing the cache
MNT=/mnt/kv-offload-ssd                        # mount point (matches root_dir)
CACHE_BUDGET_BYTES=300647710720                # 280 GiB, must be < usable ext4

# 1) Ensure the cache volume is mounted.
if ! mountpoint -q "$MNT"; then
  LOOP=$(sudo /sbin/losetup -f --show "$MODEL_CACHE_IMG")
  sudo mount "$LOOP" "$MNT"
  sudo chown "$(id -un):$(id -gn)" "$MNT"
fi

# 2) Locked (pinned) memory for the offload transfers.
sudo prlimit --pid $$ --memlock=unlimited:unlimited \
  || echo "warning: memlock not raised; transfers will not be pinned"

# 3) Drop stale offload regions left by an unclean exit.
if ! pgrep -f "vllm.entrypoints.openai.api_server" >/dev/null 2>&1; then
  rm -f /dev/shm/vllm_offload_*.mmap 2>/dev/null \
    || sudo rm -f /dev/shm/vllm_offload_*.mmap 2>/dev/null || true
fi

# 4) Restore the saved launcher route, then add the offload configuration.
cd "$MANAGER"
set -a; source run-logs/start-manager.state; set +a

export KV_TRANSFER_CONFIG='{"kv_connector":"OffloadingConnector","kv_role":"kv_both","kv_load_failure_policy":"recompute","kv_connector_extra_config":{"spec_name":"TieringOffloadingSpec","cpu_bytes_to_use":2147483648,"eviction_policy":"lru","secondary_tiers":[{"type":"fs","root_dir":"/mnt/kv-offload-ssd","n_read_threads":16,"n_write_threads":16,"eviction_policy":"fifo","max_bytes":300647710720,"min_free_bytes":8589934592,"min_file_age_seconds":10,"evict_interval_seconds":5}]}}'

exec ./launcher.sh --non-interactive
```

Keep `root_dir` and `MNT` in sync. Any model-specific environment the route
needs (for example `VLLM_QWOPUS_MTP_BF16_DRAFT=1` for the compressed-tensors
W4A16 MTP sidecar) must be exported before `exec`; `run-logs/start-manager.state`
does not record arbitrary environment variables.
