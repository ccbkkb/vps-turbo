# vps-turbo

VPS 网络与内存优化工具，附带 SOCKS5 代理落地部署脚本。面向低配 VPS（尤其是 512MB 以下）和 Alpine LXC 容器，基于 POSIX Shell 编写，无 bash 依赖。

## 目录

- [简介](#简介)
- [特性](#特性)
- [支持环境](#支持环境)
- [快速开始](#快速开始)
- [参数说明](#参数说明)
- [策略说明](#策略说明)
- [代理部署](#代理部署)
- [文件清单](#文件清单)
- [卸载](#卸载)
- [常见问题](#常见问题)
- [许可证](#许可证)

## 简介

`vps-optimize.sh` 自动检测系统环境，根据内存、磁盘、虚拟化类型智能生成优化策略，覆盖 ZRAM 压缩交换、物理 Swap、BBR 拥塞控制、内核网络与内存参数。针对代理落地场景提供 `--proxy` 模式，并支持按带宽（BDP）计算 TCP 窗口。

`deploy.sh` 将系统优化与 SOCKS5 代理部署合并为一条命令，优化完成后自动安装代理、生成随机凭据并验证出口 IP，适用于 Alpine LXC 小鸡。

## 特性

- ZRAM 压缩内存交换，自动选择最优压缩算法（lz4 / lzo-rle / lzo / zstd）
- 物理 Swapfile，支持 btrfs（自动关闭 CoW）与 fallocate 加速
- BBR 拥塞控制（内核 >= 4.9），fq / fq_codel 自动适配
- 内存与 TCP 内核参数调优，按内存档位自动分级
- 带宽感知：根据带宽与 RTT（BDP）计算 TCP 窗口，并限制在内存容量内
- 代理落地模式：并发优先配置，含端口范围、TIME_WAIT 回收、ip_forward、文件描述符上限
- MTU 手动指定，配合 tcp_mtu_probing 应对 PPPoE / 隧道环境
- 容器感知：LXC / Docker 内自动跳过 ZRAM 与 vm.* 参数（非 per-netns）
- 支持 systemd 与 OpenRC（Alpine）两种初始化系统
- 干跑模式与一键卸载

## 支持环境

| 发行版 | 包管理 | Init |
|--------|--------|------|
| Alpine Linux | apk | OpenRC |
| Debian / Ubuntu | apt | systemd |
| CentOS / Rocky / AlmaLinux | dnf / yum | systemd |

脚本基于 POSIX sh，兼容 busybox。非 TTY 环境自动禁用彩色输出。

## 快速开始

```bash
# 克隆仓库
git clone https://github.com/ccbkkb/vps-turbo.git
cd vps-turbo

# 查看帮助
sh vps-optimize.sh --help

# 干跑预览（不修改系统）
sudo sh vps-optimize.sh --dry-run

# 正式执行（需 root）
sudo sh vps-optimize.sh

# 代理落地机推荐用法
sudo sh vps-optimize.sh --proxy --bandwidth 500 --rtt 100

# 完成后重启
sudo reboot
```

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--ram, -r <size>` | 指定内存基准大小，支持 `512`、`1g`、`2gb` | 自动检测 |
| `--zram-ratio <1-95>` | ZRAM 大小占内存百分比 | 50% |
| `--swap <MB>` | 物理 Swapfile 大小（MB），`0` 表示禁用 | 256MB |
| `--swap-path <path>` | Swapfile 路径 | `/swapfile` |
| `--bandwidth, -b <Mbps>` | 指定带宽，按 BDP 计算 TCP 窗口 | 按内存档位 |
| `--rtt <ms>` | 到目标节点的 RTT，用于 BDP 计算 | 100ms |
| `--mtu <1200-1500>` | 手动设置 MTU | 不干预 |
| `--proxy, -p` | 代理落地模式（并发优先） | 关闭 |
| `--no-zram` | 禁用 ZRAM | 启用 |
| `--no-swap` | 禁用物理 Swap | 启用 |
| `--no-bbr` | 禁用 BBR，回退 cubic | 启用 |
| `--no-tcp` | 跳过全部 TCP 参数调优 | 启用 |
| `--dry-run` | 干跑模式，仅预览 | 关闭 |
| `--uninstall` | 卸载，撤销全部修改 | 关闭 |
| `--help, -h` | 显示帮助 | - |

### 带宽与 RTT

TCP 窗口基于 BDP（带宽延迟积）计算：

```
BDP(字节) = 带宽(Mbps) x RTT(ms) x 125
```

窗口上限取 BDP 的两倍，并钳制在物理内存的 25% 以内，避免高带宽参数挤占应用内存。建议先用 `ping` 实测到主要目标节点的 RTT，再传入 `--rtt`。

### 代理落地模式

`--proxy` 面向代理落地机（落地转发），优化方向是并发连接数而非单连接极限：

- 本地端口范围扩大至 1024-65535，避免出站连接耗尽
- tcp_fin_timeout 缩短至 15s，快速回收 TIME_WAIT
- somaxconn / syn_backlog 提升至 65536
- 启用 ip_forward（TUN / TPROXY 透明代理需要）
- nofile 上限调大（写入 limits.conf 并设置 ulimit）
- conntrack 参数仅在可写时配置，容器内自动跳过
- 单连接缓冲采用并发友好值（8-16MB），避免千连接内存爆炸

## 策略说明

按内存自动分级：

| 内存档位 | swappiness | ZRAM 比例 | Swap | 附加配置 |
|----------|-----------|-----------|------|----------|
| <= 128MB | 85 | 80% | 1024MB | journald 8M、单压缩流、极小 TCP 缓冲 |
| <= 256MB | 60 | 75% | 512MB | journald 16M、单压缩流 |
| <= 512MB | 20 | 60% | 512MB | 双压缩流 |
| > 512MB | 10 | 50% | 256MB | 标准配置 |

自动保护机制：

- 容器环境：自动禁用 ZRAM，跳过 vm.* 内存参数
- 磁盘剩余 < 1GB：启用保守策略，ZRAM 比例上调至 90%，Swap 大小按剩余磁盘收缩
- 内核不支持 BBR / ZRAM：自动降级（BBR 回退 cubic，ZRAM 仅保留物理 Swap）

## 代理部署

`deploy.sh` 在完成系统优化后自动部署 SOCKS5 代理（sixhop）：

```bash
sudo sh deploy.sh
```

脚本流程：

1. 运行 vps-optimize.sh（`--proxy` 模式 + 带宽感知）
2. 下载并安装 sixhop（musl 静态二进制）
3. 生成随机账号密码，写入 `/etc/sixhop/config.toml`
4. 注册 OpenRC 服务（开机自启、崩溃重启、nofile 调大）
5. 通过代理请求 `api.ipify.org` 验证出口 IP
6. 输出连接信息

参数可在脚本顶部调整：

| 变量 | 说明 |
|------|------|
| `BW_MBPS` | 带宽（Mbps），留空则按内存档位 |
| `RTT_MS` | 到目标节点的 RTT（ms） |
| `MTU` | 手动 MTU，留空不干预 |
| `PROXY_PORT` | SOCKS5 监听端口 |
| `SIXHOP_VERSION` | sixhop 版本号 |

重复运行 `deploy.sh` 会重新生成账号密码并重启服务（旧凭据备份到 `credentials.txt.bak`），可用于定期更换密码。

### 验证与日常管理

```bash
rc-service sixhop status          # 服务状态
rc-service sixhop restart         # 重启
cat /etc/sixhop/credentials.txt   # 查看账号密码
tail -f /var/log/sixhop.log       # 日志
curl --socks5-hostname 用户:密码@127.0.0.1:1080 https://api.ipify.org
```

### LXC 外部访问

代理监听 `0.0.0.0:<端口>`。桥接网络直接连接容器 IP；NAT 网络需在宿主机添加转发：

```bash
iptables -t nat -A PREROUTING -p tcp --dport 1080 -j DNAT --to-destination 容器IP:1080
iptables -A FORWARD -p tcp -d 容器IP --dport 1080 -j ACCEPT
```

## 文件清单

脚本创建或修改的文件：

| 路径 | 用途 |
|------|------|
| `/etc/sysctl.d/99-vps-optimize.conf` | 内核参数 |
| `/usr/local/sbin/vps-zram-init.sh` | ZRAM 初始化脚本 |
| `/usr/local/sbin/vps-zram-fini.sh` | ZRAM 清理脚本 |
| `/etc/systemd/system/zram-swap.service` | systemd ZRAM 服务 |
| `/etc/local.d/zram-swap.start` / `.stop` | OpenRC ZRAM 启动/停止脚本 |
| `/etc/systemd/journald.conf.d/99-vps-optimize.conf` | 小内存 journald 限制 |
| `/etc/security/limits.conf` | nofile 上限（代理模式） |
| `/swapfile` | 物理交换文件 |
| `/etc/fstab` | Swapfile 挂载条目 |
| `/etc/sixhop/` | 代理配置与凭据 |
| `/etc/init.d/sixhop`、`/etc/conf.d/sixhop` | 代理服务与参数 |

## 卸载

```bash
sudo sh vps-optimize.sh --uninstall
```

撤销内容包括：sysctl 配置、ZRAM 服务与脚本、Swapfile 与 fstab 条目、limits.conf 中新增行。建议卸载后重启。代理服务可单独移除：

```bash
rc-service sixhop stop
rc-update del sixhop
rm -f /etc/init.d/sixhop /etc/conf.d/sixhop
rm -rf /etc/sixhop /usr/local/bin/sixhop
```

## 常见问题

**运行后必须重启吗？**

建议重启。ZRAM 与 sysctl 即时生效，但重启可确保所有新连接使用新配置。

**ZRAM 会占多少真实内存？**

ZRAM 大小是上限而非实占，按需分配物理内存，实际占用取决于压缩率。

**容器里哪些参数不生效？**

LXC / Docker 内 ZRAM 与 vm.*（swappiness、dirty_ratio 等）不可用，脚本自动跳过；net.* 为 per-netns，正常生效。swap 在非特权容器内可能失败，仅产生警告。

**--no-tcp 与 --no-bbr 的区别？**

`--no-bbr` 仅保留 cubic 拥塞算法；`--no-tcp` 跳过全部 TCP 参数调优。

**--bandwidth 与 --proxy 同时使用？**

缓冲以代理模式的并发值优先，BDP 结果作为默认缓冲使用。

## 许可证

MIT
