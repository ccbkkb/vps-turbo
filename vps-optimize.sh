#!/bin/sh
# =============================================================================
# vps-optimize.sh — 一键 VPS 网络 & 内存优化
# 版本：2.0.1 (Fixed & Enhanced)
# 支持：Alpine / Debian / Ubuntu / CentOS / Rocky / AlmaLinux
# =============================================================================

# POSIX sh；禁止未定义变量
set -u

# ── 颜色（仅 TTY）────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    cR='\033[0;31m' cG='\033[0;32m' cY='\033[1;33m'
    cB='\033[0;34m' cC='\033[0;36m' cW='\033[1m' cN='\033[0m'
else
    cR='' cG='' cY='' cB='' cC='' cW='' cN=''
fi

log_info()  { printf "${cB}[INFO]${cN}  %s\n" "$*"; }
log_ok()    { printf "${cG}[ OK ]${cN}  %s\n" "$*"; }
log_warn()  { printf "${cY}[WARN]${cN}  %s\n" "$*"; }
log_err()   { printf "${cR}[ERR ]${cN}  %s\n" "$*" >&2; }
log_step()  { printf "\n${cW}${cC}▶ %s${cN}\n" "$*"; }
log_dry()   { printf "${cY}[DRY ]${cN}  %s\n" "$*"; }
die()       { log_err "$*"; exit 1; }

# =============================================================================
# 参数默认值 + 优先级标志
# =============================================================================
OPT_RAM_SPEC=""
OPT_ZRAM_RATIO=50
OPT_SWAP_MB=256
OPT_SWAP_PATH="/swapfile"
OPT_ZRAM=1
OPT_SWAP=1
OPT_BBR=1
OPT_TCP=1
OPT_DRYRUN=0
OPT_UNINSTALL=0

FLAG_ZRAM_RATIO=0
FLAG_SWAP_MB=0
FLAG_RAM_SPEC=0

# ── 固定路径 ──────────────────────────────────────────────────────────────────
SYSCTL_CONF="/etc/sysctl.d/99-vps-optimize.conf"
ZRAM_INIT_SH="/usr/local/sbin/vps-zram-init.sh"
ZRAM_FINI_SH="/usr/local/sbin/vps-zram-fini.sh"
ZRAM_SVC_SYSTEMD="/etc/systemd/system/zram-swap.service"
ZRAM_SVC_ORC_START="/etc/local.d/zram-swap.start"
ZRAM_SVC_ORC_STOP="/etc/local.d/zram-swap.stop"
JOURNAL_CONF="/etc/systemd/journald.conf.d/99-vps-optimize.conf"
MOD_BLACKLIST="/etc/modprobe.d/99-vps-optimize.conf"
STAMP="/etc/vps-optimize.stamp"

# =============================================================================
# 参数解析
# =============================================================================
parse_args() {
    while[ $# -gt 0 ]; do
        case "$1" in
            --ram|-r)
                [ $# -ge 2 ] || die "--ram 缺少参数"
                OPT_RAM_SPEC="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
                FLAG_RAM_SPEC=1; shift 2 ;;
            --zram-ratio)
                [ $# -ge 2 ] || die "--zram-ratio 缺少参数"
                OPT_ZRAM_RATIO="$2"
                FLAG_ZRAM_RATIO=1
                ( expr "$OPT_ZRAM_RATIO" + 0 >/dev/null 2>&1 ) || die "--zram-ratio 必须为整数"[ "$OPT_ZRAM_RATIO" -ge 1 ] &&[ "$OPT_ZRAM_RATIO" -le 95 ] \
                    || die "--zram-ratio 需在 1-95 之间，当前：${OPT_ZRAM_RATIO}"
                shift 2 ;;
            --swap)[ $# -ge 2 ] || die "--swap 缺少参数"
                OPT_SWAP_MB="$2"
                FLAG_SWAP_MB=1
                ( expr "$OPT_SWAP_MB" + 0 >/dev/null 2>&1 ) || die "--swap 必须为整数（MB）"
                [ "$OPT_SWAP_MB" -eq 0 ] && OPT_SWAP=0
                shift 2 ;;
            --swap-path)  [ $# -ge 2 ] || die "--swap-path 缺少参数"; OPT_SWAP_PATH="$2"; shift 2 ;;
            --no-zram)    OPT_ZRAM=0;      shift ;;
            --no-swap)    OPT_SWAP=0;      shift ;;
            --no-bbr)     OPT_BBR=0;       shift ;;
            --no-tcp)     OPT_TCP=0;       shift ;;
            --dry-run)    OPT_DRYRUN=1;    shift ;;
            --uninstall)  OPT_UNINSTALL=1; shift ;;
            --help|-h)
                printf "用法: sh $0 [选项]\n支持选项: --ram <size>, --zram-ratio <pct>, --swap <mb>, --no-zram, --no-swap, --uninstall\n"
                exit 0 ;;
            *)  log_warn "未知参数 '$1'（忽略）"; shift ;;
        esac
    done
}

xrun() { [ "$OPT_DRYRUN" -eq 1 ] && { log_dry "$*"; return 0; }; sh -c "$*" || { log_warn "命令失败：$*"; return 1; }; }
xrun_q() { [ "$OPT_DRYRUN" -eq 1 ] && { log_dry "$*"; return 0; }; sh -c "$*" >/dev/null 2>&1 || true; }
has() { command -v "$1" >/dev/null 2>&1; }
kge() { [ "$K_MAJOR" -gt "$1" ] && return 0;[ "$K_MAJOR" -eq "$1" ] && [ "$K_MINOR" -ge "$2" ] && return 0; return 1; }
to_mb() {
    _s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    _n="$(printf '%s' "$_s" | grep -o '^[0-9]*')"
    _u="$(printf '%s' "$_s" | sed 's/^[0-9]*//')"
    case "$_u" in
        g|gb) printf '%d' "$(( _n * 1024 ))" ;;
        t|tb) printf '%d' "$(( _n * 1024 * 1024 ))" ;;
        *)    printf '%d' "$_n" ;;
    esac
}
set_zram_ratio() { [ "$FLAG_ZRAM_RATIO" -eq 0 ] && OPT_ZRAM_RATIO="$1" || true; }
set_swap_mb()    {[ "$FLAG_SWAP_MB"    -eq 0 ] && OPT_SWAP_MB="$1"    || true; }

# =============================================================================
# 系统检测
# =============================================================================
check_root() { [ "$(id -u)" -eq 0 ] || die "请以 root 运行"; }

detect_distro() {
    DISTRO="unknown"; PKG_MGR=""; INIT_SYS="systemd"
    if [ -f /etc/alpine-release ]; then
        DISTRO="alpine"; PKG_MGR="apk"; INIT_SYS="openrc"
    elif [ -f /etc/debian_version ]; then
        PKG_MGR="apt"
        grep -qi ubuntu /etc/os-release 2>/dev/null && DISTRO="ubuntu" || DISTRO="debian"
    elif[ -f /etc/redhat-release ] || [ -f /etc/centos-release ]; then
        DISTRO="rhel"
        PKG_MGR="$(has dnf && echo dnf || echo yum)"
    fi
    if[ "$INIT_SYS" = "systemd" ] && ! has systemctl; then INIT_SYS="openrc"; fi
    log_info "发行版=${DISTRO}  包管理=${PKG_MGR:-未知}  Init=${INIT_SYS}"
}

detect_kernel() {
    KERNEL_VER="$(uname -r)"
    K_MAJOR="${KERNEL_VER%%.*}"
    _rest="${KERNEL_VER#*.}"
    K_MINOR="${_rest%%.*}"
    K_MAJOR="${K_MAJOR%%[!0-9]*}"
    K_MINOR="${K_MINOR%%[!0-9]*}"

    SUPPORT_BBR=0; kge 4 9 && SUPPORT_BBR=1
    SUPPORT_ZRAM=0
    if lsmod 2>/dev/null | grep -q '^zram' || modprobe -n zram >/dev/null 2>&1 || [ -d /sys/class/zram-control ] ||[ -f /sys/block/zram0/comp_algorithm ]; then
        SUPPORT_ZRAM=1
    fi
    SUPPORT_FQ=0
    has tc && tc qdisc replace dev lo root fq 2>/dev/null && { SUPPORT_FQ=1; tc qdisc del dev lo root 2>/dev/null || true; }
    log_info "内核=${KERNEL_VER}  BBR=${SUPPORT_BBR}  ZRAM=${SUPPORT_ZRAM}  FQ=${SUPPORT_FQ}"
}

detect_virt() {
    VIRT_TYPE="unknown"; IS_CONTAINER=0
    has systemd-detect-virt && VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"
    if[ -z "$VIRT_TYPE" ] || [ "$VIRT_TYPE" = "none" ] ||[ "$VIRT_TYPE" = "unknown" ]; then
        grep -qiE 'QEMU|KVM' /proc/cpuinfo 2>/dev/null && VIRT_TYPE="kvm"[ -f /proc/xen/capabilities ] && VIRT_TYPE="xen"
    fi
    case "${VIRT_TYPE:-}" in
        lxc*|openvz*|container|podman) IS_CONTAINER=1 ;;
        *) grep -q 'docker\|lxc\|kubepods' /proc/1/cgroup 2>/dev/null && IS_CONTAINER=1 || true ;;
    esac
    log_info "虚拟化=${VIRT_TYPE}  容器=${IS_CONTAINER}"
}

detect_memory() {
    MEM_TOTAL_KB="$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')"
    MEM_TOTAL_MB="$(( MEM_TOTAL_KB / 1024 ))"
    if[ "$FLAG_RAM_SPEC" -eq 1 ] && [ -n "$OPT_RAM_SPEC" ]; then
        EFFECTIVE_MB="$(to_mb "$OPT_RAM_SPEC")"[ "$EFFECTIVE_MB" -gt 0 ] || die "--ram 参数解析失败"
    else
        EFFECTIVE_MB="$MEM_TOTAL_MB"
    fi
    log_info "RAM=${MEM_TOTAL_MB}MB (计算基准=${EFFECTIVE_MB}MB)"
}

detect_disk() {
    _dir="$(dirname "$OPT_SWAP_PATH")"
    [ -d "$_dir" ] || _dir="/"  # 防止目录未创建时 df 失败
    DISK_FREE_MB="$(df -m "$_dir" 2>/dev/null | awk 'NR==2{print $4}')"
    if[ -z "$DISK_FREE_MB" ] || ! expr "$DISK_FREE_MB" + 0 >/dev/null 2>&1; then
        DISK_FREE_MB="$(df "$_dir" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}')"
    fi
    [ -z "$DISK_FREE_MB" ] && DISK_FREE_MB=9999
    IS_TINY_DISK=0
    [ "$DISK_FREE_MB" -lt 1024 ] && IS_TINY_DISK=1
    log_info "磁盘剩余=${DISK_FREE_MB}MB"
}

# =============================================================================
# 策略引擎
# =============================================================================
compute_policy() {
    IS_TINY=0; IS_MICRO=0; VM_SWAPPINESS=10; VM_DIRTY_RATIO=40; VM_DIRTY_BG=10
    VM_MIN_FREE_KB=32768; ZRAM_STREAMS=2; NET_RMEM_MAX=134217728; NET_WMEM_MAX=134217728
    NET_SOMAXCONN=32768; NET_BACKLOG=32768

    if[ "$FLAG_RAM_SPEC" -eq 1 ]; then
        if [ "$EFFECTIVE_MB" -le 128 ]; then set_zram_ratio 80; set_swap_mb 1024
        elif[ "$EFFECTIVE_MB" -le 256 ]; then set_zram_ratio 75; set_swap_mb 512
        elif [ "$EFFECTIVE_MB" -le 512 ]; then set_zram_ratio 60; set_swap_mb 512
        fi
    fi

    if [ "$EFFECTIVE_MB" -le 128 ]; then
        IS_TINY=1; IS_MICRO=1
        set_zram_ratio 80; set_swap_mb 1024
        VM_SWAPPINESS=85; VM_DIRTY_RATIO=15; VM_DIRTY_BG=3
        VM_MIN_FREE_KB=4096; ZRAM_STREAMS=1
        NET_RMEM_MAX=4194304; NET_WMEM_MAX=4194304; NET_SOMAXCONN=128; NET_BACKLOG=128
    elif[ "$EFFECTIVE_MB" -le 256 ]; then
        IS_TINY=1
        set_zram_ratio 75; set_swap_mb 512
        VM_SWAPPINESS=60; VM_DIRTY_RATIO=25; VM_DIRTY_BG=8
        VM_MIN_FREE_KB=8192; ZRAM_STREAMS=1
        NET_RMEM_MAX=8388608; NET_WMEM_MAX=8388608; NET_SOMAXCONN=512; NET_BACKLOG=512
    elif [ "$EFFECTIVE_MB" -le 512 ]; then
        set_zram_ratio 60; set_swap_mb 512
        VM_SWAPPINESS=20; VM_DIRTY_RATIO=35; VM_DIRTY_BG=8
        VM_MIN_FREE_KB=16384; ZRAM_STREAMS=2
        NET_RMEM_MAX=33554432; NET_WMEM_MAX=33554432; NET_SOMAXCONN=4096; NET_BACKLOG=4096
    fi

    if [ "$IS_CONTAINER" -eq 1 ]; then
        log_warn "容器环境，禁用 ZRAM"
        OPT_ZRAM=0
    fi

    if[ "$DISK_FREE_MB" -lt 1024 ]; then
        IS_TINY_DISK=1
        log_warn "磁盘紧张，启用保守策略"
        set_zram_ratio 90
        if[ "$FLAG_SWAP_MB" -eq 0 ]; then
            _want=256[ "$EFFECTIVE_MB" -le 128 ] && _want=128
            _max=$(( DISK_FREE_MB * 60 / 100 ))[ "$_want" -gt "$_max" ] && _want="$_max"
            if [ "$_want" -lt 32 ]; then OPT_SWAP=0; else OPT_SWAP_MB="$_want"; fi
        fi
        [ "$VM_SWAPPINESS" -lt 70 ] && VM_SWAPPINESS=70
        [ "$VM_MIN_FREE_KB" -gt 4096 ] && VM_MIN_FREE_KB=4096
    fi

    if[ "$OPT_SWAP" -eq 1 ] && [ "$FLAG_SWAP_MB" -eq 1 ]; then
        _safe=$(( DISK_FREE_MB * 75 / 100 ))
        if[ "$_safe" -gt 0 ] && [ "$OPT_SWAP_MB" -gt "$_safe" ]; then
            OPT_SWAP_MB="$_safe"
        fi
    fi

    ZRAM_SIZE_MB=$(( MEM_TOTAL_MB * OPT_ZRAM_RATIO / 100 ))[ "$ZRAM_SIZE_MB" -lt 32 ] && ZRAM_SIZE_MB=32
}

install_deps() {
    log_step "安装依赖"
    case "$PKG_MGR" in
        apk) xrun_q "apk update -q"; xrun "apk add --no-cache util-linux e2fsprogs iproute2 2>/dev/null || true" ;;
        apt) xrun "DEBIAN_FRONTEND=noninteractive apt-get update -qq"; xrun "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq util-linux iproute2 2>/dev/null || true" ;;
        dnf|yum) xrun "$PKG_MGR install -y -q util-linux iproute kmod 2>/dev/null || true" ;;
    esac
}

# =============================================================================
# ZRAM
# =============================================================================
_gen_zram_init() {
    printf '#!/bin/sh\n'
    printf 'ZRAM_BYTES=%d\n' "$(( ZRAM_SIZE_MB * 1024 * 1024 ))"
    printf 'ZRAM_STREAMS=%d\n' "$ZRAM_STREAMS"
    cat <<'BODY'
_cleanup() {
    for d in /dev/zram*; do[ -b "$d" ] && swapoff "$d" 2>/dev/null || true; done
    modprobe -r zram 2>/dev/null || true
    i=0; while[ -b /dev/zram0 ] && [ $i -lt 15 ]; do sleep 0.2; i=$(( i+1 )); done
}
_load() {
    modprobe zram num_devices=1 || exit 1
    i=0; while [ ! -b /dev/zram0 ] &&[ $i -lt 20 ]; do sleep 0.2; i=$(( i+1 )); done[ -b /dev/zram0 ] || exit 1
}
_pick_algo() {
    _av="$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
    for _a in lz4 lzo-rle lzo zstd; do printf '%s' "$_av" | grep -qw "$_a" && { printf '%s' "$_a"; return; }; done
}
_cleanup; _load
_algo="$(_pick_algo)"
[ -n "$_algo" ] && printf '%s' "$_algo" > /sys/block/zram0/comp_algorithm[ -f /sys/block/zram0/max_comp_streams ] && printf '%d' "$ZRAM_STREAMS" > /sys/block/zram0/max_comp_streams
printf '%d' "$ZRAM_BYTES" > /sys/block/zram0/disksize
mkswap -L zram0 /dev/zram0 >/dev/null 2>&1
swapon -p 100 /dev/zram0
BODY
}

setup_zram() {
    log_step "配置 ZRAM（${ZRAM_SIZE_MB}MB）"
    if [ "$OPT_ZRAM" -eq 0 ] || [ "$SUPPORT_ZRAM" -eq 0 ]; then return 0; fi

    if[ "$OPT_DRYRUN" -eq 0 ]; then
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
            cat <<EOF > "$ZRAM_SVC_SYSTEMD"
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

# =============================================================================
# Swapfile
# =============================================================================
setup_swap() {
    log_step "配置物理 Swapfile（${OPT_SWAP_MB}MB → ${OPT_SWAP_PATH}）"
    if [ "$OPT_SWAP" -eq 0 ]; then return 0; fi

    grep -qsw "$OPT_SWAP_PATH" /proc/swaps 2>/dev/null && xrun "swapoff ${OPT_SWAP_PATH} || true"

    if[ "$OPT_DRYRUN" -eq 0 ]; then
        _dir="$(dirname "$OPT_SWAP_PATH")"; mkdir -p "$_dir"
        _fs="$(df -T "$_dir" 2>/dev/null | awk 'NR==2{print $2}')"
        rm -f "$OPT_SWAP_PATH"

        if [ "$_fs" = "btrfs" ]; then
            touch "$OPT_SWAP_PATH"
            chattr +C "$OPT_SWAP_PATH" 2>/dev/null || true
            dd if=/dev/zero of="$OPT_SWAP_PATH" bs=1M count="$OPT_SWAP_MB" status=none
        elif has fallocate; then
            fallocate -l "${OPT_SWAP_MB}M" "$OPT_SWAP_PATH" || dd if=/dev/zero of="$OPT_SWAP_PATH" bs=1M count="$OPT_SWAP_MB" status=none
        else
            dd if=/dev/zero of="$OPT_SWAP_PATH" bs=1M count="$OPT_SWAP_MB" status=none
        fi

        chmod 600 "$OPT_SWAP_PATH"
        mkswap "$OPT_SWAP_PATH" >/dev/null 2>&1
        swapon -p 10 "$OPT_SWAP_PATH"

        # POSIX 兼容的 fstab 修改方式
        sed -i "\|^${OPT_SWAP_PATH}[[:space:]]|d" /etc/fstab 2>/dev/null || true
        echo "${OPT_SWAP_PATH} none swap sw,pri=10 0 0" >> /etc/fstab
    fi
}

# =============================================================================
# BBR & Sysctl
# =============================================================================
setup_bbr() {
    log_step "配置网络 TCP 与拥塞控制"
    CC_ALGO="cubic"; QDISC="fq_codel"
    if [ "$OPT_BBR" -eq 1 ] &&[ "$SUPPORT_BBR" -eq 1 ]; then
        CC_ALGO="bbr";[ "$SUPPORT_FQ" -eq 1 ] && QDISC="fq"
        if[ "$OPT_DRYRUN" -eq 0 ]; then
            modprobe tcp_bbr 2>/dev/null || true
            sysctl -wq net.ipv4.tcp_congestion_control="$CC_ALGO" 2>/dev/null || true
            sysctl -wq net.core.default_qdisc="$QDISC" 2>/dev/null || true
        fi
    fi
}

write_sysctl() {
    _rmem="4096 87380 ${NET_RMEM_MAX}"; _wmem="4096 65536 ${NET_WMEM_MAX}"[ "$IS_MICRO" -eq 1 ] && _rmem="4096 32768 ${NET_RMEM_MAX}" && _wmem="4096 16384 ${NET_WMEM_MAX}"

    _conf="
# 拥塞控制
net.ipv4.tcp_congestion_control = ${CC_ALGO}
net.core.default_qdisc = ${QDISC}
# 内存管理
vm.swappiness = ${VM_SWAPPINESS}
vm.vfs_cache_pressure = 50
vm.dirty_ratio = ${VM_DIRTY_RATIO}
vm.min_free_kbytes = ${VM_MIN_FREE_KB}
vm.overcommit_memory = 1
# TCP 缓冲
net.core.rmem_max = ${NET_RMEM_MAX}
net.core.wmem_max = ${NET_WMEM_MAX}
net.ipv4.tcp_rmem = ${_rmem}
net.ipv4.tcp_wmem = ${_wmem}
net.core.somaxconn = ${NET_SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${NET_SOMAXCONN}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
"
    if[ "$OPT_DRYRUN" -eq 0 ]; then
        mkdir -p /etc/sysctl.d
        printf '%s\n' "$_conf" > "$SYSCTL_CONF"
        sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1
    fi
}

# =============================================================================
# 小鸡专项优化
# =============================================================================
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

# =============================================================================
# 卸载
# =============================================================================
do_uninstall() {
    log_step "撤销所有修改"[ -f "$SYSCTL_CONF" ] && rm -f "$SYSCTL_CONF" && sysctl --system >/dev/null 2>&1 || true
    if [ "$INIT_SYS" = "openrc" ]; then[ -f "$ZRAM_SVC_ORC_STOP" ] && sh "$ZRAM_SVC_ORC_STOP" 2>/dev/null || true
        rm -f "$ZRAM_SVC_ORC_START" "$ZRAM_SVC_ORC_STOP"
    else
        systemctl disable --now zram-swap.service >/dev/null 2>&1 || true
        rm -f "$ZRAM_SVC_SYSTEMD"
    fi
    for _d in /dev/zram*; do[ -b "$_d" ] && swapoff "$_d" 2>/dev/null || true; done
    rm -f "$ZRAM_INIT_SH" "$ZRAM_FINI_SH"
    if[ -f "$OPT_SWAP_PATH" ]; then
        swapoff "$OPT_SWAP_PATH" 2>/dev/null || true
        rm -f "$OPT_SWAP_PATH"
        sed -i "\|^${OPT_SWAP_PATH}[[:space:]]|d" /etc/fstab 2>/dev/null || true
    fi
    rm -f "$JOURNAL_CONF" "$STAMP"
    log_ok "撤销完成，建议重启 (reboot)"
}

print_summary() {
    printf "\n${cW}${cC}════════════════ 配置摘要 ════════════════${cN}\n"
    swapon --show 2>/dev/null || true
    log_ok "优化配置写入完成！推荐重启服务器 (reboot) 以确保彻底生效。"
}

main() {
    parse_args "$@"
    check_root
    printf "\n${cW}${cC}╔════════════════════════════════════════════╗${cN}\n"
    printf "${cW}${cC}║   vps-optimize.sh v2.0.1 — 终极优化版      ║${cN}\n"
    printf "${cW}${cC}╚════════════════════════════════════════════╝${cN}\n\n"

    detect_distro; detect_kernel; detect_virt; detect_memory; detect_disk
    compute_policy

    if[ "$OPT_UNINSTALL" -eq 1 ]; then do_uninstall; exit 0; fi

    install_deps
    setup_zram
    setup_swap
    setup_bbr
    write_sysctl
    tiny_vps_extras

    print_summary
}

main "$@"
