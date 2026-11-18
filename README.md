# net-tune — Linux VPS 网络与高并发调优脚本

[![Built with Antigravity](https://img.shields.io/badge/Built%20with-Google%20Antigravity-4285F4?logo=google&logoColor=white)](https://antigravity.google)
[![Powered by Gemini](https://img.shields.io/badge/Co--authored%20by-Gemini-8E75B2?logo=googlegemini&logoColor=white)](https://deepmind.google/technologies/gemini/)

针对新购入独立 Linux VPS 跑 **TCP / UDP 大流量（跨境代理、专线中转、反代、QUIC / Hysteria2 / Tuic / WireGuard 等）** 场景设计的单文件网络与系统内核调优工具。坚持使用**原厂内核安全调优**，自动适配硬件资源与发行版差异，支持**交互式彩色面板**与**静默一键命令行**双模式。

## 一键地址安装

连上 VPS 粘贴运行，会自动将脚本安装为系统全局快捷命令 `net-tune`（`/usr/local/bin/net-tune`）并立即打开调优面板：

### 1. 打开交互式调优面板（推荐）

**root 用户（或 Alpine Linux）：**
```bash
curl -fsSL https://raw.githubusercontent.com/edmondxie779/net-tune/main/net-tune.sh -o /usr/local/bin/net-tune && chmod +x /usr/local/bin/net-tune && net-tune
```

**非 root 普通用户（带 `sudo`）：**
```bash
curl -fsSL https://raw.githubusercontent.com/edmondxie779/net-tune/main/net-tune.sh -o /tmp/net-tune.sh && sudo sh /tmp/net-tune.sh --install
```

> 安装完成后，以后任意时候登录 SSH 直接输入 `net-tune`（或 `sudo net-tune`）即可再次唤起面板！

### 2. 免交互新机全自动一键调优

不想进菜单手动选，直接一行命令装好 `net-tune` 并开启 **均衡通用档（BBR + FQ + 内存自适应缓冲 + 全局句柄 + 网卡多队列 RPS）**：

```bash
curl -fsSL https://raw.githubusercontent.com/edmondxie779/net-tune/main/net-tune.sh | sudo sh -s -- --auto
```
*(若当前已是 `root` 且系统无 `sudo`，去掉 `sudo ` 即可：`curl -fsSL https://raw.githubusercontent.com/edmondxie779/net-tune/main/net-tune.sh | sh -s -- --auto`)*

---

## 支持环境

| 发行版系列 | 推荐版本 | Init 与底层兼容处理 |
| :--- | :--- | :--- |
| **Ubuntu** | 22.04+ | Systemd / `procps` / `apt` |
| **Debian** | 11+ | Systemd / `procps` / `apt` |
| **AlmaLinux / Rocky Linux** | 8+ | Systemd / 自动处理 `kernel-modules-extra` (`sch_cake`) / 兼容 `sudo` `secure_path` |
| **CentOS Stream** | 9+ | Systemd / `dnf` |
| **Alpine Linux** | 3.16+ | OpenRC (`rc_ulimit`、`local.d`) / BusyBox `sysctl` 兼容 / 裸机无 `bash` 自举安装 / `musl` 识别 |

同时支持 `x86_64` 与 `aarch64`（自动识别 4K 与 64K 内存页换算协议栈水位）。

---

## 核心功能模块

1. **原厂内核拥塞控制与队列热切换**
   - 开启 `BBR` 并支持搭配 `fq`（默认推荐）、`cake`、`fq_pie`、`fq_codel`。
   - 除写入 `sysctl` 外，实时通过 `tc qdisc replace` 热切换主网卡当前队列，**无需重启立即生效**。
2. **BDP（带宽时延积）与内存保护自适应缓冲区**
   - 内置 **均衡通用档 (`balanced`)**、**跨国大带宽精准算参档 (`bdp`)**、**UDP/QUIC 强化档 (`udp`)**。
   - 根据物理内存设置单连接最大缓冲区硬上限（不超过物理内存的 `1/16`，最高 `128 MiB`），防止 512M/1G 小内存 VPS 在高并发下 OOM 死机。
3. **TCP / UDP 协议栈低延迟与抗并发细调**
   - 开启 `tcp_fastopen = 3`，关闭 `tcp_slow_start_after_idle = 0`（防止代理长连接空闲后掉回慢启动）。
   - 开启 `tcp_mtu_probing = 1`、`tcp_tw_reuse = 1`，关闭易引发部分运营商丢包的 `tcp_ecn = 0`。
   - 设置 `tcp_notsent_lowat = 131072`（128 KiB），大幅降低发送缓冲区积压造成的延迟膨胀。
   - 调大 `somaxconn`、`tcp_max_syn_backlog`、`netdev_max_backlog` 与本地端口池 `10240 65535`。
4. **全局文件句柄 (`1048576`) 与网卡多队列 (`RPS/RFS`)**
   - 同步打通内核 `fs.file-max`、PAM `limits.d`、Systemd `DefaultLimitNOFILE` 及 Alpine OpenRC `rc_ulimit`。
   - 自动调优主网卡 `txqueuelen=10000`，多核 VPS 自动计算 CPU 位图激活软中断负载均衡（RPS/RFS）并注册开机持久化。
5. **中转与周边工具箱**
   - **Conntrack 防爆表**：按内存大小扩容 `nf_conntrack_max` 与 `hashsize` 哈希桶，缩短超时回收周期（默认仅在已加载模块或手动开启时介入，避免纯无状态节点额外开销）。
   - **流量转发**：一键开启/关闭 IPv4 & IPv6 `ip_forward`。
   - **出站优先级**：切换 `/etc/gai.conf` IPv4 / IPv6 出站优先级（自动识别 Alpine `musl` 差异）。
   - **Swap 管理**：兼容 Ext4 / XFS / Btrfs 创建 `/swapfile` 并设 `vm.swappiness = 10`。
6. **独立配置、在线自更新与一键无痕回滚**
   - 所有配置采用 `/etc/sysctl.d/99-net-tune.conf` 等独立 drop-in 文件管理，不污染系统原厂 `/etc/sysctl.conf`。
   - 首次执行自动快照备份至 `/etc/net-tune/backup/`，随时通过菜单或 `net-tune --rollback` 一键还原，或 `net-tune --uninstall` 彻底卸载。

---

## 常用命令速查

安装后可直接在终端运行 `net-tune`（非 root 用户加 `sudo`）：

```bash
net-tune                                         # 打开交互式彩色调优面板
net-tune --auto                                  # 一键应用均衡通用档
net-tune --profile bdp --bw 2500 --rtt 160       # 按 2.5Gbps 带宽、160ms RTT 精准计算 BDP 缓冲
net-tune --profile udp --qdisc cake              # UDP / QUIC 强化档 + CAKE 队列
net-tune --auto --enable-forward --conntrack     # 中转机一键调优并开启转发与连接跟踪扩容
net-tune --auto --swap 1024                      # 调优同时创建 1024 MiB Swap
net-tune --status                                # 查看当前网络内核状态与体检报告（无需 root）
net-tune --update                                # 从 GitHub 在线更新脚本至最新版
net-tune --rollback                              # 一键回滚至调优前默认配置
net-tune --uninstall                             # 回滚所有参数并彻底卸载 net-tune 命令
```
