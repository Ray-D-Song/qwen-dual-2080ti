# systemd 部署包

把 Definitive Edition 的路线作为受管服务运行的 systemd 单元参考实现，外加一个健康看门狗。用 `deploy/install.sh` 安装；除你传入的路径外，这里没有任何与特定机器绑定的内容。

## 为什么用 systemd 单元而不是从 shell 启动

`launcher.sh` 用 `nohup setsid` 脱离终端，这能扛住终端关闭，但**扛不住它所在 systemd cgroup 的拆除**。从属于另一个服务的交互式 shell 里启动的模型，会在那个服务重启的瞬间被 SIGKILL，而 vLLM 日志里连 traceback 都不会有。把它作为独立单元运行，就有了独立的 cgroup、`Restart=on-failure` 和开机自启。

## 内容

| 文件 | 用途 |
| --- | --- |
| `vllm-swift.service.in` | 服务模板；由 `install.sh` 替换路径、用户、端口和服务模型名。 |
| `vllm-swift-healthcheck.sh` | 看门狗探测脚本。 |
| `vllm-swift-healthcheck.service` | 运行探测的 oneshot 单元。 |
| `vllm-swift-healthcheck.timer` | 开机 5 分钟后触发一次，之后每 2 分钟一次。 |
| `install.sh` | 安装并启用以上全部。 |

## 安装

```bash
sudo deploy/install.sh \
  --launch-script /path/to/vllm-kvoffload-launch.sh \
  --cache-mnt     /path/to/kv-offload-ssd
```

`--manager-dir` 默认为仓库根目录。PID 文件路径需要用到服务模型名，它从 `<manager-dir>/run-logs/start-manager.state` 读取。加上 `--restart` 可把新定义立即应用到正在运行的服务；否则它会沿用先前加载的定义，直到下次重启。

缓存卷必须写进 `/etc/fstab`（带 `nofail`），这样重启后 `RequiresMountsFor=` 才能让引擎排在挂载之后启动。参见 [KV 缓存卸载与分层说明](../docs/kv-offload-tiering.zh-CN.md)。

## 看门狗能检测什么

| 信号 | 是否检测 |
| --- | --- |
| API server 进程消失 / 单元失败 | 是 |
| `GET /health` 返回 503（引擎已报告死亡） | 是 |
| 缓存卷未挂载 | 是 |
| 缓存卷可用空间过低 | 仅记录警告 |
| 引擎卡死但仍自报健康 | **否** |

`/health` 是对 API server 的标志位检查，而不是对引擎的一次往返，所以模型繁忙时它依然能响应，不会在负载下产生误判。代价是：尚未把自己标记为出错的卡死引擎检测不到。

连续失败 5 次后看门狗会重启该单元，受每小时 3 次的重启预算约束。重启动作本身失败也会消耗预算，因此「怎么都重启不起来」的服务会退避，而不是陷入死循环。故意的 `systemctl stop` 不会被对抗：`Result` 为 `success` 的非活动单元会被视为有意停止。

## 配置

编辑 `/etc/default/vllm-swift-healthcheck`：

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `VLLM_UNIT` | `vllm-swift.service` | 被监视的单元。 |
| `VLLM_HEALTH_URL` | `http://127.0.0.1:<port>/health` | 探测地址。 |
| `VLLM_CACHE_MNT` | 来自 `--cache-mnt` | 检查是否存在及剩余空间的挂载点。 |
| `VLLM_FAIL_THRESHOLD` | `5` | 重启前允许的连续失败次数。 |
| `VLLM_RESTART_BUDGET` | `3` | 每个窗口内允许的重启次数。 |
| `VLLM_BUDGET_WINDOW` | `3600` | 预算窗口（秒）。 |
| `VLLM_MIN_FREE_BYTES` | `10737418240` | 剩余空间告警阈值（10 GiB）。 |
| `VLLM_DISABLE_FLAG` | `/etc/vllm-swift-healthcheck.disabled` | 该文件存在时看门狗什么都不做。 |

通过环境变量提供的值优先于该文件，因此 systemd drop-in
（`Environment=VLLM_FAIL_THRESHOLD=2`）或一次性 CLI 运行都能覆盖它，而无需编辑文件。该文件只提供默认值。

若 `VLLM_UNIT` 指向 systemd 不认识的单元，探测会以非零码退出并打印明确的
`ERROR:` 行，而不是静默什么都不做。

要在不停止模型的前提下暂停监视，创建禁用标志文件：

```bash
sudo touch /etc/vllm-swift-healthcheck.disabled   # 暂停
sudo rm /etc/vllm-swift-healthcheck.disabled      # 恢复
```

维护时想停服务又不想被看门狗拉起，直接 `sudo systemctl stop vllm-swift` 就够了——该停止会被识别为有意操作。若想让探测彻底跳过，则用上面的标志文件。

## 查看

```bash
systemctl status vllm-swift.service
systemctl status vllm-swift-healthcheck.timer
systemctl list-timers vllm-swift-healthcheck.timer
/usr/local/libexec/vllm-swift-healthcheck.sh; echo "exit=$?"   # 立即探测一次
journalctl -u vllm-swift-healthcheck -n 50
```

探测输出以 `vllm-swift-healthcheck:` 为前缀。健康时静默；失败时记录
`FAIL (n/5): <原因>`，恢复时记录 `recovered after <n> consecutive failure(s)`。

## 卸载

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
