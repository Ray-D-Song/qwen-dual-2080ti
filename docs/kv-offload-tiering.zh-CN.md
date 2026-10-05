# KV 缓存卸载与分层

`TieringOffloadingSpec` 把放不进 GPU 显存的 KV cache 块卸载出去，让重复前缀可以被复用而不是重算。它有两层：

| 层 | 介质 | 角色 |
| --- | --- | --- |
| 主层（Primary） | CPU（`/dev/shm` mmap） | **必需的中转网关**。GPU↔卸载的所有字节都要经它转发。由 `cpu_bytes_to_use` 决定大小。 |
| 二级层（Secondary） | `fs`（文件系统） | 真正的缓存。未配置淘汰预算时，块会一直保留。 |

## CPU 主层无法移除

二级层没有直接访问 GPU 显存的能力，CPU 主层是唯一进出通道。`cpu_bytes_to_use` 是必填项，主层也是必需的构造参数。若想让磁盘承担全部缓存、CPU 层只做中转，应当**把它调小**，而不是试图删掉它。

调小对已有缓存是安全的：缓存目录名是块几何信息（`blocks_per_file`、`dtype`、`kv_cache_groups`、并行度）的哈希，`cpu_bytes_to_use` 不参与其中。而改动 `blocks_per_chunk` / `block_size` / `dtype` **会**改变该哈希，等于换到全新命名空间，旧目录成为孤儿（需手动删除）。

`cpu_bytes_to_use` 至少要能容纳一个 chunk，否则共享区域无法 mmap；launcher 现在会对此报出明确错误。

## 启用方式

Definitive Edition 的 `launcher.sh` 会读取 `KV_TRANSFER_CONFIG` 并作为 `--kv-transfer-config` 追加。这个环境变量就是全部配置：

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

`kv_role` 必须是 `kv_both` 才能同时存储和加载。配合
`kv_load_failure_policy: recompute`，读不回来的块（例如 FIFO 在 lookup 与 load 之间把它淘汰了）会改为重算，而不是让请求失败。

## 参数

顶层（`kv_connector_extra_config`）：

| 键 | 必需 | 含义 |
| --- | --- | --- |
| `spec_name` | 是 | `TieringOffloadingSpec` |
| `cpu_bytes_to_use` | 是 | CPU 中转层的字节数。必须 ≥ 一个 chunk。 |
| `eviction_policy` | 否 | **主层（CPU）**策略：`lru`（默认）或 `arc`。 |
| `blocks_per_chunk` | 否 | 每个 chunk 合并的块数，默认 `1`。会改变缓存命名空间。 |
| `block_size` | 否 | 以 token 计的 chunk 大小，必须是 GPU 块大小的整数倍。与 `blocks_per_chunk` 互斥。 |
| `secondary_tiers` | 否 | 二级层配置列表。 |

`fs` 层：

| 键 | 默认 | 含义 |
| --- | --- | --- |
| `root_dir` | — | 缓存根目录。`max_bytes` 针对的是它下面本层自己的子目录，而非整个根目录。 |
| `n_read_threads` / `n_write_threads` | `16` | I/O 线程数。 |
| `eviction_policy` | `fifo` | 仅支持 `fifo`。**与顶层同名键含义不同**，顶层那个管的是 CPU 层。 |
| `max_bytes` | 未设置 | 本层的字节预算。不设置则永久保留块（旧行为）。 |
| `min_free_bytes` | 未设置 | 所在文件系统的 `statvfs` 可用空间下限；低于它也会触发淘汰。ENOSPC 安全网。 |
| `min_file_age_seconds` | `10` | 比这更年轻的块不淘汰，避免删掉正在 promoted 的块。 |
| `evict_interval_seconds` | `5` | 后台淘汰线程的巡检周期。 |
| `enable_kv_events` / `locality` | — | KV 事件上报与 LOCAL/REMOTE 标记。 |

## FIFO 淘汰

淘汰**优先删除最早写入**的块。顺序取自块文件的 `mtime`，在这里它是精确的：块文件按内容哈希命名、经 `os.replace` 一次性写入且之后永不改写，因此 `mtime` 就是插入时间。这也让策略在重启后依然正确，并且多个实例共享同一 `root_dir` 时同样成立。

淘汰运行在独立守护线程上，不会占用传输线程池。未配置预算时，该层行为与之前完全一致。

## 容量规划

`max_bytes` 必须明显低于文件系统可用的数据区。先确认实际可用量：

```bash
df -h /mnt/kv-offload-ssd                 # 可用大小、已用、可用
sudo tune2fs -l /dev/loopN | grep -i reserved   # 保留块百分比
```

ext4 元数据使得挂载后的容量小于镜像；若创建文件系统时未使用 `-m 0`，保留块对非特权用户不可用。请按**上报值**留出余量，用于本层的 `config.json` 以及卷上其它内容。

参考部署（双 RTX 2080 Ti，300 GiB 镜像）：

| 量 | 值 |
| --- | --- |
| 镜像 / 可用 ext4 | 300 GiB / 294.2 GiB（`reserved=0%`） |
| `cpu_bytes_to_use` | `2147483648`（2 GiB）→ 38 chunks，`/dev/shm` 区域 2.14 GB |
| `max_bytes` | `300647710720`（280 GiB），约 14 GiB 余量 |
| `min_free_bytes` | `8589934592`（8 GiB） |
| 实测 | 真实流量下 48 次淘汰，稳定收敛在预算处；0 次分配失败 |

## 卷写满时会发生什么

未配置预算时，卷写满**不会**让引擎崩溃：每次存储逐块失败，worker 记录
`Job <id> block I/O failed: [Errno 28] No space left on device`，该块只是没被缓存，服务继续。目录永远不会自行缩小，于是磁盘层静默地不再起作用。配置 `max_bytes` 正是把它变成一个可控、自管理的缓存。

## 运维注意

- **`/dev/shm` 是启动前置条件。** 中转区域按 `cpu_bytes_to_use` 分配，tmpfs 放不下时引擎会拒绝启动。8 GiB 中转层需要 `/dev/shm` 有 8 GiB 可用。
- **清理残留区域。** 调度侧 mmap（`/dev/shm/vllm_offload_<engine_id>.mmap`）在关闭时不会 unlink，被 kill 的实例会把它留下。启动新实例前应删除，但只能在没有任何 vLLM 进程运行时操作。
- **中转层过小会导致存储被静默丢弃。** 腾不出 chunk 时 `prepare_store` 返回 `None`，连接器计入一次分配失败并跳过该块；launcher 会为此打印限流告警。正常流量下若出现该告警，应调大 `cpu_bytes_to_use`。

## Operator 配置样本

保存为与 `launcher.sh` 同级的 `vllm-kvoffload-launch.sh`，按需修改顶部四个变量。内容与已验证的部署一致。

```bash
#!/usr/bin/env bash
# 用已保存的路线启动服务，附加 CPU 中转层 + SSD KV 缓存，并启用 FIFO 淘汰。
set -euo pipefail

MANAGER=/path/to/vLLM-2080Ti-Definitive        # launcher 检出目录
MODEL_CACHE_IMG=/path/to/kv-offload-ssd.img    # 承载缓存的稀疏镜像
MNT=/mnt/kv-offload-ssd                        # 挂载点（与 root_dir 一致）
CACHE_BUDGET_BYTES=300647710720                # 280 GiB，必须小于可用 ext4

# 1) 确保缓存卷已挂载。
if ! mountpoint -q "$MNT"; then
  LOOP=$(sudo /sbin/losetup -f --show "$MODEL_CACHE_IMG")
  sudo mount "$LOOP" "$MNT"
  sudo chown "$(id -un):$(id -gn)" "$MNT"
fi

# 2) 为卸载传输锁定（pinned）内存。
sudo prlimit --pid $$ --memlock=unlimited:unlimited \
  || echo "警告: memlock 未放开，传输将不是 pinned"

# 3) 清理上次异常退出残留的卸载区域。
if ! pgrep -f "vllm.entrypoints.openai.api_server" >/dev/null 2>&1; then
  rm -f /dev/shm/vllm_offload_*.mmap 2>/dev/null \
    || sudo rm -f /dev/shm/vllm_offload_*.mmap 2>/dev/null || true
fi

# 4) 恢复已保存的 launcher 路线，再附加卸载配置。
cd "$MANAGER"
set -a; source run-logs/start-manager.state; set +a

export KV_TRANSFER_CONFIG='{"kv_connector":"OffloadingConnector","kv_role":"kv_both","kv_load_failure_policy":"recompute","kv_connector_extra_config":{"spec_name":"TieringOffloadingSpec","cpu_bytes_to_use":2147483648,"eviction_policy":"lru","secondary_tiers":[{"type":"fs","root_dir":"/mnt/kv-offload-ssd","n_read_threads":16,"n_write_threads":16,"eviction_policy":"fifo","max_bytes":300647710720,"min_free_bytes":8589934592,"min_file_age_seconds":10,"evict_interval_seconds":5}]}}'

exec ./launcher.sh --non-interactive
```

`root_dir` 与 `MNT` 必须保持一致。路线所需的模型专属环境变量（例如 compressed-tensors W4A16 的 MTP sidecar 需要 `VLLM_QWOPUS_MTP_BF16_DRAFT=1`）必须在 `exec` 之前导出；`run-logs/start-manager.state` 不会记录任意环境变量。
