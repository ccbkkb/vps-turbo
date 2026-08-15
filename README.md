# 📦 vps-turbo / vps-optimize.sh

> 一键 VPS 网络 & 内存优化脚本 · POSIX Shell 编写，兼容性极强

`vps-optimize.sh` 是一个面向低配 VPS（尤其是 512MB 以下的小鸡）的一键优化工具。它会自动检测系统环境，并根据内存大小智能地配置 **ZRAM 压缩内存交换**、**物理 Swapfile**、**BBR 拥塞控制** 以及一系列 **内核网络/内存参数**，让"内存焦虑"的小鸡跑得更流畅。

![Version](https://img.shields.io/badge/version-2.0.1-blue)
![Shell](https://img.shields.io/badge/shell-POSIX%20sh-green)

---

## ✨ 特性

| 模块 | 说明 |
|------|------|
| 🧠 **ZRAM 压缩交换** | 利用内存压缩（lz4 / lzo-rle / lzo / zstd，自动挑选最优算法）虚拟出高速交换空间，秒杀磁盘 Swap |
| 💾 **物理 Swapfile** | 自动创建、挂载并写入 fstab，btrfs 文件系统自动关闭 CoW，优先使用 `fallocate` 提速 |
| 🚀 **BBR 拥塞控制** | 内核 ≥ 4.9 时自动开启 BBR + fq/fq_codel，显著提升跨国线路吞吐 |
| ⚙️ **内核参数调优** | swappiness、dirty_ratio、TCP 缓冲区、somaxconn、tcp_fastopen、mtu_probing 等一网打尽 |
| 🤖 **策略引擎** | 根据内存/磁盘自动分级（≤128M、≤256M、≤512M、>512M），不同配置差异化调优 |
| 🧹 **一键卸载** | `--uninstall` 完整撤销所有修改，包括 systemd 服务 / openrc 脚本 / fstab / sysctl |
| 🧪 **干跑模式** | `--dry-run` 只打印将要执行的命令，不实际修改系统，放心预览 |

## 🖥️ 支持的系统

- **Alpine Linux**（OpenRC + apk）
- **Debian / Ubuntu**（systemd + apt）
- **CentOS / Rocky / AlmaLinux**（systemd + dnf/yum）

> 脚本基于 POSIX sh 编写，`bash` 依赖为零；输出带彩色日志（非 TTY 环境自动禁用颜色）。

---

## 🚀 快速开始

### 安装 & 运行

```bash
# 下载脚本
wget -O vps-optimize.sh https://raw.githubusercontent.com/ccbkkb/vps-turbo/main/vps-optimize.sh

# 赋予执行权限并运行（需要 root）
chmod +x vps-optimize.sh
sudo sh vps-optimize.sh
```

运行结束后**建议重启**，确保所有内核参数与交换空间完全生效：

```bash
sudo reboot
```

### 查看效果

```bash
swapon --show        # 查看 ZRAM + Swapfile
sysctl net.ipv4.tcp_congestion_control   # 确认 BBR 已启用
free -h              # 查看内存情况
```

---

## ⚙️ 全部参数

```bash
sh vps-optimize.sh [选项]
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--ram, -r <size>` | 手动指定内存基准大小（支持 `512`、`1g`、`2gb` 等格式），用于覆盖自动检测 | 自动检测 |
| `--zram-ratio <1-95>` | ZRAM 大小 = 内存 × 该百分比 | 50% |
| `--swap <MB>` | 物理 Swapfile 大小（MB），设为 `0` 表示不创建 | 256MB |
| `--swap-path <path>` | Swapfile 路径 | `/swapfile` |
| `--no-zram` | 禁用 ZRAM 模块 | 启用 |
| `--no-swap` | 禁用物理 Swapfile | 启用 |
| `--no-bbr` | 禁用 BBR 配置（回退 cubic + fq_codel） | 启用 |
| `--no-tcp` | 禁用 TCP 参数调优 | 启用 |
| `--dry-run` | 干跑模式，仅预览不修改 | 关闭 |
| `--uninstall` | 卸载，撤销全部修改 | 关闭 |
| `--help, -h` | 显示帮助 | — |

### 常用示例

```bash
# 快速优化（全自动）
sudo sh vps-optimize.sh

# 指定 1G 内存小鸡，ZRAM 用 60% 内存，Swap 512MB
sudo sh vps-optimize.sh --ram 1g --zram-ratio 60 --swap 512

# 磁盘紧张，只要 ZRAM 不要物理 Swap
sudo sh vps-optimize.sh --no-swap --zram-ratio 90

# 先预览再执行
sudo sh vps-optimize.sh --dry-run
sudo sh vps-optimize.sh

# 一键卸载并恢复
sudo sh vps-optimize.sh --uninstall
```

---

## 🧠 策略引擎：按内存自动分级

脚本会自动检测物理内存并套用不同的优化策略：

| 内存档位 | swappiness | ZRAM 比例 | Swap 大小 | 附加优化 |
|----------|-----------|-----------|-----------|----------|
| **≤ 128MB**（Micro） | 85 | 80% | 1024MB | journald 限制 8M、单压缩流、极小 TCP 缓冲 |
| **≤ 256MB**（Tiny） | 60 | 75% | 512MB | journald 限制 16M、单压缩流 |
| **≤ 512MB** | 20 | 60% | 512MB | 双压缩流 |
| **> 512MB** | 10 | 50% | 256MB | 标准配置 |

> 也可用 `--ram` 强制指定基准，方便在测试机 / 容器上模拟不同内存档位。

### 自动保护机制

- 🐳 **容器环境**（LXC / Docker / OpenVZ / Podman 等）：自动禁用 ZRAM（容器内无法加载内核模块）
- 💾 **磁盘剩余 < 1GB**：自动启用保守策略（ZRAM 比例上调至 90%，Swap 大小按磁盘剩余 60% 收缩，过小时自动跳过 Swapfile）
- 🔍 **内核不支持 BBR / ZRAM**：自动检测并降级（BBR → cubic，ZRAM → 仅物理 Swap）

---

## 📁 脚本创建/修改的文件

| 路径 | 用途 |
|------|------|
| `/etc/sysctl.d/99-vps-optimize.conf` | 内核参数配置 |
| `/usr/local/sbin/vps-zram-init.sh` | ZRAM 初始化脚本 |
| `/usr/local/sbin/vps-zram-fini.sh` | ZRAM 清理脚本 |
| `/etc/systemd/system/zram-swap.service` | ZRAM systemd 服务（systemd 系统） |
| `/etc/local.d/zram-swap.start` / `.stop` | ZRAM OpenRC 启动/停止脚本（Alpine） |
| `/etc/systemd/journald.conf.d/99-vps-optimize.conf` | 小鸡 journald 内存限制（仅 ≤256MB） |
| `/swapfile` | 物理交换文件 |
| `/etc/fstab` | 追加 Swapfile 开机挂载条目 |
| `/etc/vps-optimize.stamp` | 安装标记 |

---

## ⚠️ 注意事项

1. **必须 root 运行**，脚本会直接写入 `/etc`、加载内核模块并操作交换分区。
2. **容器 / 虚拟化环境**：KVM / Xen / VMware 完全支持；LXC / Docker / OpenVZ 等容器会跳过 ZRAM，仅做内核参数与 Swap 优化。
3. **Swapfile 在 SSD 上推荐使用**；机械盘上读写偏慢，ZRAM 优先级更高（`pri=100`）会先被使用。
4. **卸载后建议重启**，脚本会在最后提示 `reboot`。
5. 部分云厂商可能限制内核模块加载（如 `modprobe zram` 失败），脚本会静默降级，不会中断。

---

## 🧰 依赖

脚本会自动通过各发行版包管理器安装（util-linux、iproute2 等），无需手动处理：

- **Alpine**：`apk add util-linux e2fsprogs iproute2`
- **Debian/Ubuntu**：`apt-get install util-linux iproute2`
- **CentOS/Rocky/Alma**：`dnf/yum install util-linux iproute kmod`

---

## ❓ FAQ

**Q：运行后必须重启吗？**
建议重启。ZRAM 与 sysctl 已即时生效，但部分参数（如 TCP 缓冲）在连接建立时读取，重启可确保所有连接使用新配置。

**Q：ZRAM 会占多少真实内存？**
ZRAM 大小是"上限"而非"实占"。它按需分配物理内存，实际占用取决于压缩后的数据量，通常远小于标称大小。

**Q：--no-tcp 和 --no-bbr 有什么区别？**
`--no-bbr` 仅禁用 BBR（保持默认 cubic），`--no-tcp` 则跳过所有 TCP 相关 sysctl 调优。

**Q：能在自己的系统上安全运行吗？**
脚本自带全套检测（发行版/内核/虚拟化/内存/磁盘）与降级逻辑，但也建议先在 `--dry-run` 模式确认预期行为。

---

## 📜 许可证

本项目基于 MIT 许可证开源，欢迎自由使用与二次开发。
