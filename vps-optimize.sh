#!/bin/sh
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# Alpine LXC 小鸡一键：系统优化 + SOCKS5 代理部署 + 验证
# 适用：Alpine 3.23 LXC + OpenRC，root 直接粘贴
# 组成：vps-optimize.sh v2.1.0（内嵌） + sixhop SOCKS5
# 修复：compute_policy 返回码 / apply_sysctl 兜底 / LXC 容器检测
# ═══════════════════════════════════════════════════════════════

# ─────────── 可调参数 ───────────
BW_MBPS="500"          # 带宽(Mbps)，留空=按内存档位
RTT_MS="100"           # 到主目标节点 RTT(ms)，建议先 ping 实测
MTU=""                 # 手动 MTU(如 1450)，留空=不干预
PROXY_PORT="1080"      # SOCKS5 监听端口
SIXHOP_VERSION="v0.0.2.1"
case "$(uname -m)" in
    aarch64|arm64) SIXHOP_ARCH="aarch64" ;;
    *)             SIXHOP_ARCH="x86_64"  ;;
esac
# ────────────────────────────────

[ "$(id -u)" -eq 0 ] || { echo "请以 root 运行"; exit 1; }

# ============================================================
# 第 1 部分：vps-optimize.sh v2.1.0（内嵌，函数化）
# ============================================================
if [ -t 1 ]; then
    cR='\033[0;31m' cG='\033[0;32m' cY='\033[1;33m'
    cB='\033[0;34m' cC='\033[0;36m' cW='\033[1m' cN='\033[0m'
else
    cR='' cG='' cY='' cB='' cC='' cW='' cN=''
fi
log_info() { printf "${cB}[INFO]${cN} %s\n" "$*"; }
log_ok()   { printf "${cG}[ OK ]${cN} %s\n" "$*"; }
log_warn() { printf "${cY}[WARN]${cN} %s\n" "$*"; }
log_err()  { printf "${cR}[ERR ]${cN} %s\n" "$*" >&2; }
log_step() { printf "\n${cW}${cC}▶ %s${cN}\n" "$*"; }
log_dry()  { printf "${cY}[DRY ]${cN} %s\n" "$*"; }
die()      { log_err "$*"; exit 1; }

# ---- 优化器默认值 ----
OPT_RAM_SPEC=""; OPT_ZRAM_RATIO=50; OPT_SWAP_MB=256; OPT_SWAP_PATH="/swapfile"
OPT_ZRAM=1; OPT_SWAP=1; OPT_BBR=1; OPT_TCP=1; OPT_DRYRUN=0; OPT_UNINSTALL=0
OPT_BW_MBPS=""; OPT_RTT_MS=100; OPT_MTU=""; OPT_PROXY=0
FLAG_ZRAM_RATIO=0; FLAG_SWAP_MB=0; FLAG_RAM_SPEC=0
SYSCTL_CONF="/etc/sysctl.d/99-vps-optimize.conf"
ZRAM_INIT_SH="/usr/local/sbin/vps-zram-init.sh"
ZRAM_FINI_SH="/usr/local/sbin/vps-zram-fini.sh"
ZRAM_SVC_SYSTEMD="/etc/systemd/system/zram-swap.service"
ZRAM_SVC_ORC_START="/etc/local.d/zram-swap.start"
ZRAM_SVC_ORC_STOP="/etc/local.d/zram-swap.stop"
JOURNAL_CONF="/etc/systemd/journald.conf.d/99-vps-optimize.conf"
STAMP="/etc/vps-optimize.stamp"
LIMITS_CONF="/etc/security/limits.conf"

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --ram|-r)
            [ $# -ge 2 ] || die "--ram 缺少参数"
            OPT_RAM_SPEC="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
            FLAG_RAM_SPEC=1; shift 2 ;;
        --zram-ratio)
            [ $# -ge 2 ] || die "--zram-ratio 缺少参数"
            OPT_ZRAM_RATIO="$2"; FLAG_ZRAM_RATIO=1
            ( expr "$OPT_ZRAM_RATIO" + 0 >/dev/null 2>&1 ) || die "--zram-ratio 必须为整数"
            [ "$OPT_ZRAM_RATIO" -ge 1 ] && [ "$OPT_ZRAM_RATIO" -le 95 ] || die "--zram-ratio 需在 1-95"
            shift 2 ;;
        --swap)
            [ $# -ge 2 ] || die "--swap 缺少参数"
            OPT_SWAP_MB="$2"; FLAG_SWAP_MB=1
            ( expr "$OPT_SWAP_MB" + 0 >/dev/null 2>&1 ) || die "--swap 必须为整数（MB）"
            [ "$OPT_SWAP_MB" -eq 0 ] && OPT_SWAP=0
            shift 2 ;;
        --swap-path) [ $# -ge 2 ] || die "--swap-path 缺少参数"; OPT_SWAP_PATH="$2"; shift 2 ;;
        --bandwidth|-b)
            [ $# -ge 2 ] || die "--bandwidth 缺少参数"
            OPT_BW_MBPS="$2"
            ( expr "$OPT_BW_MBPS" + 0 >/dev/null 2>&1 ) || die "--bandwidth 必须为整数（Mbps）"
            [ "$OPT_BW_MBPS" -ge 1 ] && [ "$OPT_BW_MBPS" -le 100000 ] || die "--bandwidth 需在 1-100000"
            shift 2 ;;
        --rtt)
            [ $# -ge 2 ] || die "--rtt 缺少参数"
            OPT_RTT_MS="$2"
            ( expr "$OPT_RTT_MS" + 0 >/dev/null 2>&1 ) || die "--rtt 必须为整数（毫秒）"
            [ "$OPT_RTT_MS" -ge 1 ] && [ "$OPT_RTT_MS" -le 5000 ] || die "--rtt 需在 1-5000"
            shift 2 ;;
        --mtu)
            [ $# -ge 2 ] || die "--mtu 缺少参数"
            OPT_MTU="$2"
            ( expr "$OPT_MTU" + 0 >/dev/null 2>&1 ) || die "--mtu 必须为整数"
            [ "$OPT_MTU" -ge 1200 ] && [ "$OPT_MTU" -le 1500 ] || die "--mtu 需在 1200-1500"
            shift 2 ;;
        --proxy|-p) OPT_PROXY=1; shift ;;
        --no-zram)  OPT_ZRAM=0; shift ;;
        --no-swap)  OPT_SWAP=0; shift ;;
        --no-bbr)   OPT_BBR=0; shift ;;
        --no-tcp)   OPT_TCP=0; shift ;;
        --dry-run)  OPT_DRYRUN=1; shift ;;
        --uninstall) OPT_UNINSTALL=1; shift ;;
        --help|-h) printf "用法: sh $0 [选项]\n"; exit 0 ;;
        *) log_warn "未知参数 '$1'（忽略）"; shift ;;
        esac
    done
}

xrun()   { [ "$OPT_DRYRUN" -eq 1 ] && { log_dry "$*"; return 0; }; sh -c "$*" || { log_warn "命令失败：$*"; return 1; }; }
xrun_q() { [ "$OPT_DRYRUN" -eq 1 ] && { log_dry "$*"; return 0; }; sh -c "$*" >/dev/null 2>&1 || true; }
has()    { command -v "$1" >/dev/null 2>&1; }
kge()    { [ "$K_MAJOR" -gt "$1" ] && return 0; [ "$K_MAJOR" -eq "$1" ] && [ "$K_MINOR" -ge "$2" ] && return 0; return 1; }
to_mb() {
    _s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    _n="$(printf '%s' "$_s" | grep -o '^[0-9]*')"
    _u="$(printf '%s' "$_s" | sed 's/^[0-9]*//')"
    case "$_u" in
        g|gb) printf '%d' "$(( _n * 1024 ))" ;;
        t|tb) printf '%d' "$(( _n * 1024 * 1024 ))" ;;
        *)     printf '%d' "$_n" ;;
    esac
}
set_zram_ratio() { [ "$FLAG_ZRAM_RATIO" -eq 0 ] && OPT_ZRAM_RATIO="$1" || true; }
set_swap_mb()    { [ "$FLAG_SWAP_MB" -eq 0 ] && OPT_SWAP_MB="$1" || true; }

# 【修复 2】apply_sysctl：任何分支都保证返回 0，避免 set -e 误杀
apply_sysctl() {
    _f="$1"
    if [ "$INIT_SYS" = "openrc" ] && has rc-service; then
        rc-service sysctl restart >/dev/null 2>&1 || sysctl -p "$_f" >/dev/null 2>&1 || true
    else
        sysctl -p "$_f" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
    fi
}
reload_sysctl() {
    if [ "$INIT_SYS" = "openrc" ] && has rc-service; then
        rc-service sysctl restart >/dev/null 2>&1 || true
    else
        sysctl --system >/dev/null 2>&1 || true
    fi
}

check_root() { [ "$(id -u)" -eq 0 ] || die "请以 root 运行"; }

detect_distro() {
    DISTRO="unknown"; PKG_MGR=""; INIT_SYS="systemd"
    if [ -f /etc/alpine-release ]; then
        DISTRO="alpine"; PKG_MGR="apk"; INIT_SYS="openrc"
    elif [ -f /etc/debian_version ]; then
        PKG_MGR="apt"
        grep -qi ubuntu /etc/os-release 2>/dev/null && DISTRO="ubuntu" || DISTRO="debian"
    elif [ -f /etc/redhat-release ] || [ -f /etc/centos-release ]; then
        DISTRO="rhel"; PKG_MGR="$(has dnf && echo dnf || echo yum)"
    fi
    if [ "$INIT_SYS" = "systemd" ] && ! has systemctl; then INIT_SYS="openrc"; fi
    log_info "发行版=${DISTRO} 包管理=${PKG_MGR:-未知} Init=${INIT_SYS}"
}

detect_kernel() {
    KERNEL_VER="$(uname -r)"
    K_MAJOR="${KERNEL_VER%%.*}"; _rest="${KERNEL_VER#*.}"; K_MINOR="${_rest%%.*}"
    K_MAJOR="${K_MAJOR%%[!0-9]*}"; K_MINOR="${K_MINOR%%[!0-9]*}"
    SUPPORT_BBR=0; kge 4 9 && SUPPORT_BBR=1
    SUPPORT_ZRAM=0
    if lsmod 2>/dev/null | grep -q '^zram' || modprobe -n zram >/dev/null 2>&1 \
        || [ -d /sys/class/zram-control ] || [ -f /sys/block/zram0/comp_algorithm ]; then
        SUPPORT_ZRAM=1
    fi
    SUPPORT_FQ=0
    has tc && tc qdisc replace dev lo root fq 2>/dev/null && { SUPPORT_FQ=1; tc qdisc del dev lo root 2>/dev/null || true; }
    log_info "内核=${KERNEL_VER} BBR=${SUPPORT_BBR} ZRAM=${SUPPORT_ZRAM} FQ=${SUPPORT_FQ}"
}

detect_virt() {
    VIRT_TYPE="unknown"; IS_CONTAINER=0
    has systemd-detect-virt && VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"
    if [ -z "$VIRT_TYPE" ] || [ "$VIRT_TYPE" = "none" ] || [ "$VIRT_TYPE" = "unknown" ]; then
        grep -qiE 'QEMU|KVM' /proc/cpuinfo 2>/dev/null && VIRT_TYPE="kvm"
        [ -f /proc/xen/capabilities ] && VIRT_TYPE="xen"
    fi
    case "${VIRT_TYPE:-}" in
        lxc*|openvz*|container|podman) IS_CONTAINER=1 ;;
        *) grep -q 'docker\|lxc\|kubepods' /proc/1/cgroup 2>/dev/null && IS_CONTAINER=1 || true ;;
    esac
    # 【修复 3】无 systemd 时的 LXC/Docker 兜底检测
    if grep -qa 'container=lxc' /proc/1/environ 2>/dev/null \
        || [ -f /.dockerenv ] \
        || grep -qaE 'lxc|docker' /proc/self/mountinfo 2>/dev/null; then
        IS_CONTAINER=1
    fi
    log_info "虚拟化=${VIRT_TYPE} 容器=${IS_CONTAINER}"
}

detect_memory() {
    MEM_TOTAL_KB="$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')"
    MEM_TOTAL_MB="$(( MEM_TOTAL_KB / 1024 ))"
    if [ "$FLAG_RAM_SPEC" -eq 1 ] && [ -n "$OPT_RAM_SPEC" ]; then
        EFFECTIVE_MB="$(to_mb "$OPT_RAM_SPEC")"
        [ "$EFFECTIVE_MB" -gt 0 ] || die "--ram 参数解析失败"
    else
        EFFECTIVE_MB="$MEM_TOTAL_MB"
    fi
    log_info "RAM=${MEM_TOTAL_MB}MB (计算基准=${EFFECTIVE_MB}MB)"
}

detect_disk() {
    _dir="$(dirname "$OPT_SWAP_PATH")"; [ -d "$_dir" ] || _dir="/"
    DISK_FREE_MB="$(df -m "$_dir" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -z "$DISK_FREE_MB" ] || ! expr "$DISK_FREE_MB" + 0 >/dev/null 2>&1; then
        DISK_FREE_MB="$(df "$_dir" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}')"
    fi
    [ -z "$DISK_FREE_MB" ] && DISK_FREE_MB=9999
    IS_TINY_DISK=0; [ "$DISK_FREE_MB" -lt 1024 ] && IS_TINY_DISK=1
    log_info "磁盘剩余=${DISK_FREE_MB}MB"
}

compute_policy() {
    IS_TINY=0; IS_MICRO=0; VM_CONF_ACTIVE=1
    VM_SWAPPINESS=10; VM_DIRTY_RATIO=40; VM_DIRTY_BG=10
    VM_MIN_FREE_KB=32768; ZRAM_STREAMS=2
    NET_RMEM_MAX=134217728; NET_WMEM_MAX=134217728
    NET_RMEM_DEFAULT=87380; NET_WMEM_DEFAULT=65536
    NET_SOMAXCONN=32768; NET_BACKLOG=32768; NET_OPTMEM_MAX=20480
    IP_LOCAL_PORT_RANGE="1024 65535"
    TCP_FIN_TIMEOUT=30; TCP_MAX_TW_BUCKETS=65536
    TCP_KEEPALIVE_TIME=7200; TCP_KEEPALIVE_INTVL=75; TCP_KEEPALIVE_PROBES=9
    FILE_MAX=65536; IP_FORWARD=0

    if [ "$FLAG_RAM_SPEC" -eq 1 ]; then
        if   [ "$EFFECTIVE_MB" -le 128 ]; then set_zram_ratio 80; set_swap_mb 1024
        elif [ "$EFFECTIVE_MB" -le 256 ]; then set_zram_ratio 75; set_swap_mb 512
        elif [ "$EFFECTIVE_MB" -le 512 ]; then set_zram_ratio 60; set_swap_mb 512
        fi
    fi

    if [ "$EFFECTIVE_MB" -le 128 ]; then
        IS_TINY=1; IS_MICRO=1
        set_zram_ratio 80; set_swap_mb 1024
        VM_SWAPPINESS=85; VM_DIRTY_RATIO=15; VM_DIRTY_BG=3
        VM_MIN_FREE_KB=4096; ZRAM_STREAMS=1
        NET_RMEM_MAX=4194304; NET_WMEM_MAX=4194304
        NET_RMEM_DEFAULT=32768; NET_WMEM_DEFAULT=16384
        NET_SOMAXCONN=128; NET_BACKLOG=128
    elif [ "$EFFECTIVE_MB" -le 256 ]; then
        IS_TINY=1
        set_zram_ratio 75; set_swap_mb 512
        VM_SWAPPINESS=60; VM_DIRTY_RATIO=25; VM_DIRTY_BG=8
        VM_MIN_FREE_KB=8192; ZRAM_STREAMS=1
        NET_RMEM_MAX=8388608; NET_WMEM_MAX=8388608
        NET_SOMAXCONN=512; NET_BACKLOG=512
    elif [ "$EFFECTIVE_MB" -le 512 ]; then
        set_zram_ratio 60; set_swap_mb 512
        VM_SWAPPINESS=20; VM_DIRTY_RATIO=35; VM_DIRTY_BG=8
        VM_MIN_FREE_KB=16384; ZRAM_STREAMS=2
        NET_RMEM_MAX=33554432; NET_WMEM_MAX=33554432
        NET_SOMAXCONN=4096; NET_BACKLOG=4096
    fi

    # 带宽感知：BDP 计算 TCP 窗口
    if [ -n "$OPT_BW_MBPS" ]; then
        _bdp=$(( OPT_BW_MBPS * OPT_RTT_MS * 125 ))
        _buf=$(( _bdp * 2 ))
        _buf_min=$(( 2 * 1024 * 1024 ))
        _buf_max=$(( EFFECTIVE_MB * 1024 * 1024 / 4 ))
        [ "$_buf" -lt "$_buf_min" ] && _buf="$_buf_min"
        [ "$_buf" -gt "$_buf_max" ] && _buf="$_buf_max"
        NET_RMEM_MAX=$_buf; NET_WMEM_MAX=$_buf
        NET_RMEM_DEFAULT=$_bdp; NET_WMEM_DEFAULT=$_bdp
        [ "$NET_RMEM_DEFAULT" -lt 65536 ] && NET_RMEM_DEFAULT=65536
        [ "$NET_WMEM_DEFAULT" -lt 65536 ] && NET_WMEM_DEFAULT=65536
        log_info "带宽=${OPT_BW_MBPS}Mbps RTT=${OPT_RTT_MS}ms BDP=$(( _bdp / 1024 ))KiB 窗口上限=$(( _buf / 1024 / 1024 ))MiB"
    fi

    # 代理落地模式：并发优先
    if [ "$OPT_PROXY" -eq 1 ]; then
        NET_SOMAXCONN=65536; NET_BACKLOG=65536
        IP_LOCAL_PORT_RANGE="1024 65535"
        TCP_FIN_TIMEOUT=15; TCP_MAX_TW_BUCKETS=65536
        TCP_KEEPALIVE_TIME=600; TCP_KEEPALIVE_INTVL=15; TCP_KEEPALIVE_PROBES=3
        FILE_MAX=131072; NET_OPTMEM_MAX=20480; IP_FORWARD=1
        if [ "$EFFECTIVE_MB" -le 256 ]; then
            NET_RMEM_MAX=$(( 8 * 1024 * 1024 )); NET_WMEM_MAX=$(( 8 * 1024 * 1024 ))
        else
            NET_RMEM_MAX=$(( 16 * 1024 * 1024 )); NET_WMEM_MAX=$(( 16 * 1024 * 1024 ))
        fi
        NET_RMEM_DEFAULT=65536; NET_WMEM_DEFAULT=65536
        log_info "代理模式：并发优先 somaxconn=${NET_SOMAXCONN} 端口=${IP_LOCAL_PORT_RANGE} 缓冲上限=$(( NET_RMEM_MAX / 1024 / 1024 ))MiB"
    fi

    # 容器环境：禁 ZRAM，跳过 vm.*
    if [ "$IS_CONTAINER" -eq 1 ]; then
        log_warn "容器环境，禁用 ZRAM，跳过 vm.* 内存参数"
        OPT_ZRAM=0; VM_CONF_ACTIVE=0
    fi

    # 磁盘紧张：保守策略
    if [ "$DISK_FREE_MB" -lt 1024 ]; then
        IS_TINY_DISK=1
        log_warn "磁盘紧张，启用保守策略"
        set_zram_ratio 90
        if [ "$FLAG_SWAP_MB" -eq 0 ]; then
            _want=256; [ "$EFFECTIVE_MB" -le 128 ] && _want=128
            _max=$(( DISK_FREE_MB * 60 / 100 ))
            [ "$_want" -gt "$_max" ] && _want="$_max"
            if [ "$_want" -lt 32 ]; then OPT_SWAP=0; else OPT_SWAP_MB="$_want"; fi
        fi
        [ "$VM_SWAPPINESS" -lt 70 ] && VM_SWAPPINESS=70
        [ "$VM_MIN_FREE_KB" -gt 4096 ] && VM_MIN_FREE_KB=4096
    fi

    if [ "$OPT_SWAP" -eq 1 ] && [ "$FLAG_SWAP_MB" -eq 1 ]; then
        _safe=$(( DISK_FREE_MB * 75 / 100 ))
        if [ "$_safe" -gt 0 ] && [ "$OPT_SWAP_MB" -gt "$_safe" ]; then
            OPT_SWAP_MB="$_safe"
        fi
    fi

    ZRAM_SIZE_MB=$(( MEM_TOTAL_MB * OPT_ZRAM_RATIO / 100 ))
    [ "$ZRAM_SIZE_MB" -lt 32 ] && ZRAM_SIZE_MB=32
    # 【修复 1】强制返回 0：末尾条件为假时不再被 set -e 终止
    return 0
}

install_deps() {
    log_step "安装依赖"
    case "$PKG_MGR" in
        apk) xrun_q "apk update -q"; xrun "apk add --no-cache util-linux e2fsprogs iproute2 2>/dev/null || true" ;;
        apt) xrun "DEBIAN_FRONTEND=noninteractive apt-get update -qq || true"; xrun "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq util-linux iproute2 2>/dev/null || true" ;;
        dnf|yum) xrun "$PKG_MGR install -y -q util-linux iproute kmod 2>/dev/null || true" ;;
    esac
}

setup_mtu() {
    [ -n "$OPT_MTU" ] || return 0
    log_step "设置 MTU=${OPT_MTU}"
    _iface="$(ip route 2>/dev/null | awk '/default/{print $5; exit}')"
    [ -n "$_iface" ] || _iface="eth0"
    if [ "$OPT_DRYRUN" -eq 1 ]; then
        log_dry "ip link set $_iface mtu $OPT_MTU"; return 0
    fi
    if ip link set "$_iface" mtu "$OPT_MTU" 2>/dev/null; then
        log_ok "已设置 $_iface MTU=${OPT_MTU}（重启后失效；LXC 请在宿主配置 lxc.net.0.mtu）"
    else
        log_warn "设置 MTU 失败（LXC 容器可能不允许改 MTU，请在宿主侧配置）"
    fi
}

_gen_zram_init() {
    printf '#!/bin/sh\n'
    printf 'ZRAM_BYTES=%d\n' "$(( ZRAM_SIZE_MB * 1024 * 1024 ))"
    printf 'ZRAM_STREAMS=%d\n' "$ZRAM_STREAMS"
    cat <<'BODY'
_cleanup() {
    for d in /dev/zram*; do [ -b "$d" ] && swapoff "$d" 2>/dev/null || true; done
    modprobe -r zram 2>/dev/null || true
    i=0; while [ -b /dev/zram0 ] && [ $i -lt 15 ]; do sleep 0.2; i=$(( i+1 )); done
}
_load() {
    modprobe zram num_devices=1 || exit 1
    i=0; while [ ! -b /dev/zram0 ] && [ $i -lt 20 ]; do sleep 0.2; i=$(( i+1 )); done
    [ -b /dev/zram0 ] || exit 1
}
_pick_algo() {
    _av="$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
    for _a in lz4 lzo-rle lzo zstd; do printf '%s' "$_av" | grep -qw "$_a" && { printf '%s' "$_a"; return; }; done
}
_cleanup; _load
_algo="$(_pick_algo)"
[ -n "$_algo" ] && printf '%s' "$_algo" > /sys/block/zram0/comp_algorithm
[ -f /sys/block/zram0/max_comp_streams ] && printf '%d' "$ZRAM_STREAMS" > /sys/block/zram0/max_comp_streams
printf '%d' "$ZRAM_BYTES" > /sys/block/zram0/disksize
mkswap -L zram0 /dev/zram0 >/dev/null 2>&1
swapon -p 100 /dev/zram0
BODY
}

setup_zram() {
    log_step "配置 ZRAM（${ZRAM_SIZE_MB}MB）"
    if [ "$OPT_ZRAM" -eq 0 ] || [ "$SUPPORT_ZRAM" -eq 0 ]; then return 0; fi
    if [ "$OPT_DRYRUN" -eq 0 ]; then
        mkdir -p /usr/local/sbin
        _gen_zram_init > "$ZRAM_INIT_SH"
        printf '#!/bin/sh\nfor d in /dev/zram*; do [ -b "$d" ] && swapoff "$d" 2>/dev/null || true; done\nmodprobe -r zram 2>/dev/null || true\n' > "$ZRAM_FINI_SH"
        chmod 750 "$ZRAM_INIT_SH" "$ZRAM_FINI_SH"
        if [ "$INIT_SYS" = "openrc" ]; then
            mkdir -p /etc/local.d
            ln -sf "$ZRAM_INIT_SH" "$ZRAM_SVC_ORC_START"
            ln -sf "$ZRAM_FINI_SH" "$ZRAM_SVC_ORC_STOP"
            chmod +x "$ZRAM_SVC_ORC_START" "$ZRAM_SVC_ORC_STOP"
            rc-update add local default >/dev/null 2>&1
            sh "$ZRAM_INIT_SH" || log_warn "ZRAM 启动失败"
        else
            cat > "$ZRAM_SVC_SYSTEMD" <<EOF
[Unit]
Description=ZRAM swap
DefaultDependencies=no
After=local-fs-pre.target
Before=swap.target local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${ZRAM_INIT_SH}
ExecStop=${ZRAM_FINI_SH}
TimeoutStartSec=30
[Install]
WantedBy=swap.target
EOF
            systemctl daemon-reload
            systemctl enable --now zram-swap.service >/dev/null 2>&1 || true
        fi
    fi
}

setup_swap() {
    log_step "配置物理 Swapfile（${OPT_SWAP_MB}MB → ${OPT_SWAP_PATH}）"
    if [ "$OPT_SWAP" -eq 0 ]; then return 0; fi
    grep -qsw "$OPT_SWAP_PATH" /proc/swaps 2>/dev/null && xrun "swapoff ${OPT_SWAP_PATH} || true"
    if [ "$OPT_DRYRUN" -eq 0 ]; then
        _dir="$(dirname "$OPT_SWAP_PATH")"; mkdir -p "$_dir"
        _fs="$(df -T "$_dir" 2>/dev/null | awk 'NR==2{print $2}')"
        rm -f "$OPT_SWAP_PATH"
        if [ "$_fs" = "btrfs" ]; then
            touch "$OPT_SWAP_PATH"; chattr +C "$OPT_SWAP_PATH" 2>/dev/null || true
            dd if=/dev/zero of="$OPT_SWAP_PATH" bs=1M count="$OPT_SWAP_MB" status=none
        elif has fallocate; then
            fallocate -l "${OPT_SWAP_MB}M" "$OPT_SWAP_PATH" || dd if=/dev/zero of="$OPT_SWAP_PATH" bs=1M count="$OPT_SWAP_MB" status=none
        else
            dd if=/dev/zero of="$OPT_SWAP_PATH" bs=1M count="$OPT_SWAP_MB" status=none
        fi
        chmod 600 "$OPT_SWAP_PATH"
        mkswap "$OPT_SWAP_PATH" >/dev/null 2>&1 || true
        swapon -p 10 "$OPT_SWAP_PATH" || log_warn "swapon 失败（LXC 内可能不允许，可忽略）"
        sed -i "\|^${OPT_SWAP_PATH}[[:space:]]|d" /etc/fstab 2>/dev/null || true
        echo "${OPT_SWAP_PATH} none swap sw,pri=10 0 0" >> /etc/fstab
    fi
}

setup_bbr() {
    log_step "配置网络 TCP 与拥塞控制"
    CC_ALGO="cubic"; QDISC="fq_codel"
    if [ "$OPT_BBR" -eq 1 ] && [ "$SUPPORT_BBR" -eq 1 ]; then
        CC_ALGO="bbr"; [ "$SUPPORT_FQ" -eq 1 ] && QDISC="fq"
        if [ "$OPT_DRYRUN" -eq 0 ]; then
            modprobe tcp_bbr 2>/dev/null || true
            sysctl -wq net.ipv4.tcp_congestion_control="$CC_ALGO" 2>/dev/null || true
            sysctl -wq net.core.default_qdisc="$QDISC" 2>/dev/null || true
        fi
    fi
}

write_sysctl() {
    log_step "写入内核参数"
    if [ "$OPT_DRYRUN" -eq 1 ]; then log_dry "写入 $SYSCTL_CONF 并应用"; return 0; fi
    mkdir -p /etc/sysctl.d
    : > "$SYSCTL_CONF"

    cat >> "$SYSCTL_CONF" <<EOF
# vps-optimize v2.1.0
net.ipv4.tcp_congestion_control = ${CC_ALGO}
net.core.default_qdisc = ${QDISC}
EOF

    if [ "$VM_CONF_ACTIVE" -eq 1 ]; then
        cat >> "$SYSCTL_CONF" <<EOF
vm.swappiness = ${VM_SWAPPINESS}
vm.vfs_cache_pressure = 50
vm.dirty_ratio = ${VM_DIRTY_RATIO}
vm.min_free_kbytes = ${VM_MIN_FREE_KB}
vm.overcommit_memory = 1
EOF
    else
        log_warn "容器环境：跳过 vm.* 内存参数"
    fi

    if [ "$OPT_TCP" -eq 1 ]; then
        _rmem="4096 ${NET_RMEM_DEFAULT} ${NET_RMEM_MAX}"
        _wmem="4096 ${NET_WMEM_DEFAULT} ${NET_WMEM_MAX}"
        cat >> "$SYSCTL_CONF" <<EOF
net.core.rmem_max = ${NET_RMEM_MAX}
net.core.wmem_max = ${NET_WMEM_MAX}
net.ipv4.tcp_rmem = ${_rmem}
net.ipv4.tcp_wmem = ${_wmem}
net.core.somaxconn = ${NET_SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${NET_SOMAXCONN}
net.core.netdev_max_backlog = ${NET_BACKLOG}
net.core.optmem_max = ${NET_OPTMEM_MAX}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_slow_start_after_idle = 0
EOF
        if [ "$OPT_PROXY" -eq 1 ]; then
            cat >> "$SYSCTL_CONF" <<EOF
net.ipv4.ip_local_port_range = ${IP_LOCAL_PORT_RANGE}
net.ipv4.tcp_fin_timeout = ${TCP_FIN_TIMEOUT}
net.ipv4.tcp_max_tw_buckets = ${TCP_MAX_TW_BUCKETS}
net.ipv4.tcp_keepalive_time = ${TCP_KEEPALIVE_TIME}
net.ipv4.tcp_keepalive_intvl = ${TCP_KEEPALIVE_INTVL}
net.ipv4.tcp_keepalive_probes = ${TCP_KEEPALIVE_PROBES}
EOF
        fi
    fi

    if [ "$OPT_PROXY" -eq 1 ]; then
        cat >> "$SYSCTL_CONF" <<EOF
net.ipv4.ip_forward = ${IP_FORWARD}
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
fs.file-max = ${FILE_MAX}
EOF
    fi

    apply_sysctl "$SYSCTL_CONF"
}

proxy_extra() {
    [ "$OPT_PROXY" -eq 1 ] || return 0
    log_step "代理落地附加优化"
    if [ "$OPT_DRYRUN" -eq 1 ]; then log_dry "limits.conf / conntrack / udp 缓冲"; return 0; fi
    if [ -f "$LIMITS_CONF" ]; then
        grep -q '^# vps-optimize' "$LIMITS_CONF" 2>/dev/null || \
        cat >> "$LIMITS_CONF" <<'EOF'
# vps-optimize: proxy
* soft nofile 1048576
* hard nofile 1048576
EOF
    fi
    ulimit -n 1048576 2>/dev/null || true
    if [ -w /proc/sys/net/netfilter/nf_conntrack_max ]; then
        echo "net.netfilter.nf_conntrack_max = 32768" >> "$SYSCTL_CONF"
    fi
    if [ -w /proc/sys/net/netfilter/nf_conntrack_udp_timeout ]; then
        echo "net.netfilter.nf_conntrack_udp_timeout = 30" >> "$SYSCTL_CONF"
    fi
    if [ "$EFFECTIVE_MB" -ge 256 ]; then
        echo "net.ipv4.udp_rmem_min = 8192" >> "$SYSCTL_CONF"
        echo "net.ipv4.udp_wmem_min = 8192" >> "$SYSCTL_CONF"
    fi
    apply_sysctl "$SYSCTL_CONF"
    log_ok "nofile 上限已调大"
}

tiny_vps_extras() {
    [ "$IS_TINY" -eq 1 ] || return 0
    if [ "$INIT_SYS" = "systemd" ] && has journalctl; then
        _jmax="$([ "$IS_MICRO" -eq 1 ] && echo '8M' || echo '16M')"
        if [ "$OPT_DRYRUN" -eq 0 ]; then
            mkdir -p "$(dirname "$JOURNAL_CONF")"
            printf "[Journal]\nStorage=volatile\nRuntimeMaxUse=${_jmax}\nSystemMaxUse=${_jmax}\n" > "$JOURNAL_CONF"
            systemctl restart systemd-journald 2>/dev/null || true
        fi
    fi
}

cleanup_system() {
    if [ "$IS_TINY_DISK" -eq 1 ] && [ "$PKG_MGR" = "apk" ]; then
        log_step "清理 apk 缓存（磁盘紧张）"
        if [ "$OPT_DRYRUN" -eq 0 ]; then
            apk cache clean 2>/dev/null || true
        else
            log_dry "apk cache clean"
        fi
    fi
}

print_summary() {
    printf "\n${cW}${cC}════════════════ 配置摘要 ════════════════${cN}\n"
    swapon --show 2>/dev/null || true
    log_ok "优化配置写入完成！推荐重启服务器 (reboot) 以确保彻底生效。"
}

optimize_main() {
    parse_args "$@"
    check_root
    printf "\n${cW}${cC}▶▶ vps-optimize v2.1.0 — 系统优化 ◀◀${cN}\n\n"
    detect_distro; detect_kernel; detect_virt; detect_memory; detect_disk
    compute_policy
    if [ "$OPT_UNINSTALL" -eq 1 ]; then echo "（合并脚本中卸载请用原版）"; return 0; fi
    install_deps
    setup_mtu
    setup_zram
    setup_swap
    setup_bbr
    write_sysctl
    proxy_extra
    tiny_vps_extras
    cleanup_system
    print_summary
}

# ============================================================
# 第 2 部分：sixhop SOCKS5 部署
# ============================================================
deploy_sixhop() {
    echo; echo "== 部署 SOCKS5 代理 (sixhop ${SIXHOP_VERSION}) =="
    command -v curl >/dev/null || apk add --no-cache curl

    # 下载 musl 静态二进制
    URL="https://github.com/ccbkkb/sixhop/releases/download/${SIXHOP_VERSION}/sixhop-${SIXHOP_ARCH}-unknown-linux-musl.tar.gz"
    echo "下载: ${URL}"
    curl -fSL -o /tmp/sixhop.tar.gz "$URL"
    tar -xzf /tmp/sixhop.tar.gz -C /tmp
    install -m 0755 /tmp/sixhop /usr/local/bin/sixhop
    rm -f /tmp/sixhop.tar.gz /tmp/sixhop
    sixhop --version || true

    # 随机账号密码（重复运行 = 换新密码）
    USERNAME="u$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)"

    # 配置
    mkdir -p /etc/sixhop
    cat > /etc/sixhop/config.toml <<EOF
bind_addr = "0.0.0.0:${PROXY_PORT}"
username = "${USERNAME}"
password = "${PASSWORD}"
log_level = "info"
EOF

    umask 077
    if [ -f /etc/sixhop/credentials.txt ]; then
        cp -f /etc/sixhop/credentials.txt /etc/sixhop/credentials.txt.bak 2>/dev/null || true
    fi
    cat > /etc/sixhop/credentials.txt <<EOF
username = ${USERNAME}
password = ${PASSWORD}
EOF
    chmod 600 /etc/sixhop/credentials.txt
    umask 022

    # OpenRC 服务（开机自启 + 崩溃重启 + 大 nofile）
    cat > /etc/init.d/sixhop <<'EOF'
#!/sbin/openrc-run
name="sixhop"
description="sixhop SOCKS5 proxy"
command="/usr/local/bin/sixhop"
command_args="--config /etc/sixhop/config.toml"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sixhop.log"
error_log="/var/log/sixhop.log"
EOF
    chmod +x /etc/init.d/sixhop
    echo 'rc_ulimit="-n 1048576"' > /etc/conf.d/sixhop

    rc-update add sixhop default || true
    rc-service sixhop start 2>/dev/null || rc-service sixhop restart
}

# ============================================================
# 第 3 部分：验证 & 摘要
# ============================================================
verify_and_summary() {
    echo; echo "== 验证 =="
    sleep 1
    rc-service sixhop status || true

    IP=""
    for i in 1 2 3; do
        IP=$(curl -fsS --socks5-hostname "${USERNAME}:${PASSWORD}@127.0.0.1:${PROXY_PORT}" \
            https://api.ipify.org --max-time 15 2>/dev/null || true)
        [ -n "$IP" ] && break
        sleep 2
    done

    if [ -n "$IP" ]; then
        echo "出口 IP: ${IP}   OK 代理工作正常"
    else
        echo "出口 IP 获取失败，请检查: cat /var/log/sixhop.log"
    fi

    echo
    echo "================= 代理信息 ================="
    echo "服务器: $(hostname -I | awk '{print $1}'):${PROXY_PORT}"
    echo "用户名: ${USERNAME}"
    echo "密码:   ${PASSWORD}"
    echo "配置文件: /etc/sixhop/config.toml"
    echo "凭据备份: /etc/sixhop/credentials.txt"
    echo "日志: /var/log/sixhop.log"
    echo "============================================="
}

# ============================================================
# 执行：先优化，再部署代理，最后验证
# ============================================================
optimize_main --proxy \
    ${BW_MBPS:+--bandwidth "$BW_MBPS"} \
    --rtt "$RTT_MS" \
    ${MTU:+--mtu "$MTU"}

deploy_sixhop
verify_and_summary

echo
echo "OK 全部完成。建议稍后重启一次：reboot"
