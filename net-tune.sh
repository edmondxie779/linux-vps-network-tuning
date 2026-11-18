#!/bin/sh
# ==============================================================================
# net-tune.sh — Linux VPS 网络与系统高并发调优脚本 (TCP / UDP / BBR / BDP 自适应)
#
# 支持发行版:
#   - Ubuntu 22.04+
#   - Debian 11+
#   - AlmaLinux 8+ / Rocky Linux 8+ / CentOS Stream 9+
#   - Alpine Linux 3.16+
#
# 特性:
#   - 原厂内核安全调优 (BBR + FQ / CAKE / FQ_CODEL / FQ_PIE)
#   - 基于内存保护与 BDP (带宽时延积) 模型的动态 TCP/UDP 缓冲区计算
#   - 针对代理/中转/QUIC 场景的协议栈低延迟与抗并发细调
#   - 跨 Systemd 与 OpenRC (Alpine) 的全局句柄 (ulimit/nofile) 与持久化支持
#   - 网卡多队列软中断 (RPS/RFS)、发送队列深度与实时 tc qdisc 热切换
#   - Conntrack 连接跟踪表智能扩容、流量转发、IPv4/v6 优先级、Swap 管理
#   - 完整初始快照备份与一键无痕回滚
# ==============================================================================

# POSIX 自举引导：兼容 Alpine Linux 默认无 bash 环境，同时支持本地文件与管道安装
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if [ "$(id -u)" -eq 0 ] && command -v apk >/dev/null 2>&1; then
            printf '%s\n' "[INFO] 检测到 Alpine 环境缺少 bash，正在自动安装基础依赖..."
            apk add --no-cache bash curl ca-certificates iproute2 procps-ng >/dev/null 2>&1 \
                || apk add --no-cache bash >/dev/null 2>&1
        fi
    fi
    if command -v bash >/dev/null 2>&1; then
        if [ -f "$0" ]; then
            exec bash "$0" "$@"
        else
            # 通过 curl ... | sh 管道调用时，自动拉取到临时或系统路径再交由 bash 执行
            _bootstrap_url="https://raw.githubusercontent.com/edmondxie779/net-tune/main/net-tune.sh"
            _bootstrap_dst="/tmp/net-tune.$$.sh"
            [ "$(id -u)" -eq 0 ] && [ -d /usr/local/bin ] && _bootstrap_dst="/usr/local/bin/net-tune"
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL --retry 2 "$_bootstrap_url" -o "$_bootstrap_dst"
            elif command -v wget >/dev/null 2>&1; then
                wget -qO "$_bootstrap_dst" "$_bootstrap_url"
            fi
            if [ -s "$_bootstrap_dst" ]; then
                chmod 0755 "$_bootstrap_dst"
                exec bash "$_bootstrap_dst" "$@"
            fi
        fi
    fi
    printf '%s\n' "[ERROR] 运行此脚本需要 bash。请先安装 bash，或使用 'bash net-tune.sh' 运行。" >&2
    exit 1
fi

set -u

# ============================= 全局常量与路径 =================================
readonly SCRIPT_VERSION="1.0.0"
readonly REPO_URL="https://github.com/edmondxie779/net-tune"
readonly REPO_RAW_URL="https://raw.githubusercontent.com/edmondxie779/net-tune/main/net-tune.sh"
readonly INSTALL_BIN="/usr/local/bin/net-tune"
readonly SYMLINK_BIN="/usr/bin/net-tune"
readonly STATE_DIR="/etc/net-tune"
readonly BACKUP_DIR="${STATE_DIR}/backup"
readonly BACKUP_FILES_DIR="${BACKUP_DIR}/files"
readonly SYSCTL_SNAPSHOT="${BACKUP_DIR}/sysctl.snapshot"
readonly NIC_SCRIPT="${STATE_DIR}/nic-tune.sh"
readonly STATE_FILE="${STATE_DIR}/state.env"

readonly SYSCTL_MAIN="/etc/sysctl.d/99-net-tune.conf"
readonly SYSCTL_FORWARD="/etc/sysctl.d/98-net-tune-forward.conf"
readonly SYSCTL_SWAP="/etc/sysctl.d/97-net-tune-swap.conf"
readonly MODULES_CONF="/etc/modules-load.d/99-net-tune.conf"
readonly MODPROBE_CONF="/etc/modprobe.d/99-net-tune.conf"
readonly LIMITS_CONF="/etc/security/limits.d/99-net-tune.conf"
readonly SYSTEMD_SYS_CONF="/etc/systemd/system.conf.d/99-net-tune.conf"
readonly SYSTEMD_USR_CONF="/etc/systemd/user.conf.d/99-net-tune.conf"
readonly SYSTEMD_NIC_SVC="/etc/systemd/system/net-tune-nic.service"
readonly OPENRC_ULIMIT_SH="/etc/profile.d/99-net-tune-ulimit.sh"
readonly OPENRC_NIC_START="/etc/local.d/99-net-tune-nic.start"

readonly TARGET_NOFILE=1048576

# ============================= 终端彩色输出 ===================================
if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
fi

log_info()  { printf '%s[INFO]%s %s\n' "${C_CYAN}" "${C_RESET}" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
log_err()   { printf '%s[ERR ]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
print_hr()  { printf '%s----------------------------------------------------------------------%s\n' "${C_DIM}" "${C_RESET}"; }

# ============================= 系统环境探测 ===================================
OS_ID="unknown"
OS_VERSION_ID=""
OS_PRETTY="Unknown Linux"
OS_FAMILY="unknown"
INIT_SYSTEM="other"
VIRT_TYPE="unknown"
IS_CONTAINER=0
IS_MUSL=0
KERNEL_REL="$(uname -r 2>/dev/null || echo unknown)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"
CPU_CORES=1
MEM_TOTAL_MB=512
PAGE_SIZE=4096
PRIMARY_NIC=""

detect_environment() {
    # 1. 发行版检测
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION_ID="${VERSION_ID:-}"
        OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
    fi

    case "$OS_ID" in
        ubuntu|debian)
            OS_FAMILY="debian"
            ;;
        almalinux|rocky|centos|rhel|ol|fedora)
            OS_FAMILY="rhel"
            ;;
        alpine)
            OS_FAMILY="alpine"
            ;;
        *)
            case "${ID_LIKE:-}" in
                *debian*|*ubuntu*) OS_FAMILY="debian" ;;
                *rhel*|*centos*|*fedora*) OS_FAMILY="rhel" ;;
                *) OS_FAMILY="other" ;;
            esac
            ;;
    esac

    # 2. Init 系统检测
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif [ -f /sbin/openrc-run ] || command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="other"
    fi

    # 3. libc 检测 (Alpine musl 对 /etc/gai.conf 行为不同)
    if [ "$OS_ID" = "alpine" ] || (command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl); then
        IS_MUSL=1
    fi

    # 4. 虚拟化与容器检测
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo none)"
        if systemd-detect-virt --container >/dev/null 2>&1; then
            IS_CONTAINER=1
        fi
    else
        if [ -f /.dockerenv ]; then
            VIRT_TYPE="docker"
            IS_CONTAINER=1
        elif grep -qaE 'lxc|openvz|container=' /proc/1/environ 2>/dev/null; then
            VIRT_TYPE="container"
            IS_CONTAINER=1
        elif [ -r /sys/class/dmi/id/product_name ]; then
            local dmi
            dmi="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
            case "$dmi" in
                *KVM*|*QEMU*|*Standard\ PC*) VIRT_TYPE="kvm" ;;
                *VMware*) VIRT_TYPE="vmware" ;;
                *Virtual\ Machine*) VIRT_TYPE="microsoft" ;;
                *HVM*domU*|*Xen*) VIRT_TYPE="xen" ;;
                *) VIRT_TYPE="${dmi:-physical/vm}" ;;
            esac
        elif grep -qi hypervisor /proc/cpuinfo 2>/dev/null; then
            VIRT_TYPE="vm"
        else
            VIRT_TYPE="physical/unknown"
        fi
    fi

    # 5. CPU、物理内存与内存页大小
    if command -v nproc >/dev/null 2>&1; then
        CPU_CORES="$(nproc 2>/dev/null || echo 1)"
    elif [ -r /proc/cpuinfo ]; then
        CPU_CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
    fi
    [ "${CPU_CORES:-0}" -lt 1 ] 2>/dev/null && CPU_CORES=1

    if [ -r /proc/meminfo ]; then
        local mem_kb
        mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 524288)"
        MEM_TOTAL_MB=$(( mem_kb / 1024 ))
    fi
    [ "${MEM_TOTAL_MB:-0}" -lt 64 ] 2>/dev/null && MEM_TOTAL_MB=512

    PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo 4096)"
    [ "${PAGE_SIZE:-0}" -lt 4096 ] 2>/dev/null && PAGE_SIZE=4096

    # 6. 主出站网卡检测
    if command -v ip >/dev/null 2>&1; then
        PRIMARY_NIC="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
        if [ -z "$PRIMARY_NIC" ]; then
            PRIMARY_NIC="$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
        fi
    fi
    if [ -z "$PRIMARY_NIC" ] && [ -d /sys/class/net ]; then
        local iface
        for iface in /sys/class/net/*; do
            iface="${iface##*/}"
            [ "$iface" = "lo" ] && continue
            PRIMARY_NIC="$iface"
            break
        done
    fi
}

check_os_compatibility() {
    if [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
        log_err "当前系统不是 Linux ($(uname -s))，网络内核调优仅适用于 Linux VPS。"
        exit 1
    fi

    local major_ver="${OS_VERSION_ID%%.*}"
    local minor_ver="${OS_VERSION_ID#*.}"
    minor_ver="${minor_ver%%.*}"

    case "$OS_ID" in
        ubuntu)
            if [ "${major_ver:-0}" -lt 22 ] 2>/dev/null; then
                log_warn "当前 Ubuntu ${OS_VERSION_ID} 低于推荐版本 22.04+，部分新内核特性可能自动跳过。"
            fi
            ;;
        debian)
            if [ "${major_ver:-0}" -lt 11 ] 2>/dev/null; then
                log_warn "当前 Debian ${OS_VERSION_ID} 低于推荐版本 11+，部分参数可能自动跳过。"
            fi
            ;;
        almalinux|rocky)
            if [ "${major_ver:-0}" -lt 8 ] 2>/dev/null; then
                log_warn "当前 ${OS_PRETTY} 低于推荐版本 8+。"
            fi
            ;;
        centos)
            if [ "${major_ver:-0}" -lt 9 ] 2>/dev/null; then
                log_warn "当前 ${OS_PRETTY} 低于推荐版本 CentOS Stream 9+。"
            fi
            ;;
        alpine)
            if [ "${major_ver:-0}" -lt 3 ] 2>/dev/null || { [ "${major_ver:-0}" -eq 3 ] && [ "${minor_ver:-0}" -lt 16 ] 2>/dev/null; }; then
                log_warn "当前 Alpine ${OS_VERSION_ID} 低于推荐版本 3.16+。"
            fi
            ;;
        *)
            log_warn "当前发行版 (${OS_PRETTY}) 不在核心测试列表内，将以通用 Linux 模式运行。"
            ;;
    esac
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_err "此操作需要 root 权限，请使用 sudo 或切换至 root 用户运行。"
        exit 1
    fi
}

ensure_runtime_tools() {
    # 针对极简系统补齐 ip / tc / sysctl 所需基础包
    local need_ip=0
    command -v ip >/dev/null 2>&1 || need_ip=1
    command -v tc >/dev/null 2>&1 || need_ip=1

    if [ "$need_ip" -eq 1 ]; then
        log_info "正在补齐基础网络工具包 (iproute2)..."
        case "$OS_FAMILY" in
            debian)
                DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 procps >/dev/null 2>&1 || true
                ;;
            rhel)
                dnf install -y -q iproute iproute-tc procps-ng >/dev/null 2>&1 || yum install -y -q iproute iproute-tc procps-ng >/dev/null 2>&1 || true
                ;;
            alpine)
                apk add --no-cache iproute2 procps-ng >/dev/null 2>&1 || true
                ;;
        esac
        detect_environment
    fi
}

# ============================= 工具与备份函数 =================================
human_bytes() {
    local bytes="${1:-0}"
    if [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        awk -v b="$bytes" 'BEGIN { printf "%.1f MiB", b/1048576 }'
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        awk -v b="$bytes" 'BEGIN { printf "%.1f KiB", b/1024 }'
    else
        printf '%s B' "$bytes"
    fi
}

read_sysctl() {
    local key="$1"
    local path="/proc/sys/${key//.//}"
    if [ -r "$path" ]; then
        tr '\t\n' '  ' < "$path" | sed 's/  */ /g; s/^ //; s/ $//'
    else
        printf 'N/A'
    fi
}

sysctl_writable() {
    local key="$1"
    local path="/proc/sys/${key//.//}"
    [ -e "$path" ] && [ -w "$path" ]
}

reload_all_sysctl() {
    if sysctl --help 2>&1 | grep -q -- '--system'; then
        sysctl --system >/dev/null 2>&1 || true
    else
        # 兼容 Alpine BusyBox sysctl (无 --system 选项)
        local f
        [ -f /etc/sysctl.conf ] && sysctl -e -p /etc/sysctl.conf >/dev/null 2>&1 || true
        for f in /lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /etc/sysctl.d/*.conf; do
            [ -f "$f" ] && sysctl -e -p "$f" >/dev/null 2>&1 || true
        done
    fi
}

SNAPSHOT_KEYS=(
    net.core.default_qdisc
    net.ipv4.tcp_congestion_control
    net.core.rmem_max
    net.core.wmem_max
    net.core.rmem_default
    net.core.wmem_default
    net.core.optmem_max
    net.core.somaxconn
    net.core.netdev_max_backlog
    net.core.netdev_budget
    net.core.netdev_budget_usecs
    net.ipv4.tcp_rmem
    net.ipv4.tcp_wmem
    net.ipv4.tcp_mem
    net.ipv4.udp_mem
    net.ipv4.udp_rmem_min
    net.ipv4.udp_wmem_min
    net.ipv4.tcp_fastopen
    net.ipv4.tcp_slow_start_after_idle
    net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_tw_reuse
    net.ipv4.tcp_fin_timeout
    net.ipv4.tcp_keepalive_time
    net.ipv4.tcp_keepalive_intvl
    net.ipv4.tcp_keepalive_probes
    net.ipv4.tcp_max_syn_backlog
    net.ipv4.tcp_max_tw_buckets
    net.ipv4.tcp_syn_retries
    net.ipv4.tcp_synack_retries
    net.ipv4.tcp_retries2
    net.ipv4.tcp_ecn
    net.ipv4.tcp_notsent_lowat
    net.ipv4.ip_local_port_range
    net.ipv4.ip_forward
    net.ipv6.conf.all.forwarding
    fs.file-max
    fs.nr_open
    vm.swappiness
    vm.vfs_cache_pressure
    net.netfilter.nf_conntrack_max
    net.netfilter.nf_conntrack_tcp_timeout_established
    net.netfilter.nf_conntrack_udp_timeout
    net.netfilter.nf_conntrack_udp_timeout_stream
)

ensure_initial_backup() {
    mkdir -p "$BACKUP_FILES_DIR"
    if [ ! -f "$SYSCTL_SNAPSHOT" ]; then
        log_info "首次调优：正在创建系统初始参数快照 (${BACKUP_DIR})..."
        : > "$SYSCTL_SNAPSHOT"
        local k val
        for k in "${SNAPSHOT_KEYS[@]}"; do
            val="$(read_sysctl "$k")"
            if [ "$val" != "N/A" ]; then
                printf '%s=%s\n' "$k" "$val" >> "$SYSCTL_SNAPSHOT"
            fi
        done
    fi

    local cfg base
    for cfg in /etc/gai.conf /etc/rc.conf /etc/fstab /etc/sysctl.conf; do
        base="${cfg##*/}"
        if [ -f "$cfg" ] && [ ! -f "${BACKUP_FILES_DIR}/${base}.orig" ]; then
            cp -a "$cfg" "${BACKUP_FILES_DIR}/${base}.orig"
        fi
    done
}

backup_file_once() {
    local file="$1"
    mkdir -p "$BACKUP_FILES_DIR"
    local base="${file##*/}"
    if [ -f "$file" ] && [ ! -f "${BACKUP_FILES_DIR}/${base}.orig" ]; then
        cp -a "$file" "${BACKUP_FILES_DIR}/${base}.orig"
    fi
}

# ============================= 内核模块与拥塞队列 =============================
persist_kernel_modules() {
    mkdir -p /etc/modules-load.d
    cat > "$MODULES_CONF" <<EOF
# Managed by net-tune.sh
tcp_bbr
EOF
    local mod
    for mod in "$@"; do
        [ -z "$mod" ] && continue
        if ! grep -qx "$mod" "$MODULES_CONF" 2>/dev/null; then
            printf '%s\n' "$mod" >> "$MODULES_CONF"
        fi
    done

    if [ "$INIT_SYSTEM" = "openrc" ] && command -v rc-update >/dev/null 2>&1; then
        rc-update add modules boot >/dev/null 2>&1 || true
        rc-update add sysctl boot >/dev/null 2>&1 || true
    fi
}

ensure_bbr_available() {
    modprobe tcp_bbr >/dev/null 2>&1 || true
    local avail
    avail="$(read_sysctl net.ipv4.tcp_available_congestion_control)"
    case " $avail " in
        *" bbr "*)
            return 0
            ;;
        *)
            log_warn "当前内核 (${KERNEL_REL}) 未暴露 bbr 模块 (可用算法: ${avail})，将保持原拥塞控制算法。"
            return 1
            ;;
    esac
}

ensure_qdisc_available() {
    local target_qdisc="$1"
    local allow_install="${2:-1}"
    local prev_qdisc
    prev_qdisc="$(read_sysctl net.core.default_qdisc)"

    modprobe "sch_${target_qdisc}" >/dev/null 2>&1 || true
    if sysctl -w "net.core.default_qdisc=${target_qdisc}" >/dev/null 2>&1; then
        [ "$prev_qdisc" != "N/A" ] && sysctl -w "net.core.default_qdisc=${prev_qdisc}" >/dev/null 2>&1 || true
        return 0
    fi

    # RHEL 系 (Alma/Rocky/CentOS) 的 sch_cake 通常位于 kernel-modules-extra 包中
    if [ "$target_qdisc" = "cake" ] && [ "$OS_FAMILY" = "rhel" ] && [ "$allow_install" -eq 1 ]; then
        log_info "RHEL 系默认精简内核未自带 sch_cake，正在尝试安装 kernel-modules-extra..."
        dnf install -y -q "kernel-modules-extra-${KERNEL_REL}" >/dev/null 2>&1 \
            || dnf install -y -q kernel-modules-extra >/dev/null 2>&1 || true
        modprobe sch_cake >/dev/null 2>&1 || true
        if sysctl -w "net.core.default_qdisc=cake" >/dev/null 2>&1; then
            [ "$prev_qdisc" != "N/A" ] && sysctl -w "net.core.default_qdisc=${prev_qdisc}" >/dev/null 2>&1 || true
            return 0
        fi
    fi

    return 1
}

apply_live_qdisc() {
    local qdisc="$1"
    if [ -n "$PRIMARY_NIC" ] && command -v tc >/dev/null 2>&1; then
        tc qdisc replace dev "$PRIMARY_NIC" root "$qdisc" >/dev/null 2>&1 || true
    fi
}

# ============================= BDP 与内存自适应算参 ===========================
# 根据内存和场景计算安全且充足的缓冲区参数
CALC_MAX_BUF=33554432
CALC_DEF_RMEM=262144
CALC_DEF_WMEM=262144
CALC_UDP_MIN=16384
CALC_BACKLOG=16384
CALC_BUDGET=600
CALC_BUDGET_USECS=8000
CALC_TCP_MEM=""
CALC_UDP_MEM=""

calculate_buffers() {
    local mode="$1"           # balanced | bdp | udp
    local bw_mbps="${2:-1000}"
    local rtt_ms="${3:-150}"

    # 单连接最大缓冲区内存保护上限: 不超过物理内存的 1/16，且在 [8 MiB, 128 MiB] 之间
    local ram_bytes=$(( MEM_TOTAL_MB * 1024 * 1024 ))
    local ram_cap=$(( ram_bytes / 16 ))
    local min_cap=8388608       # 8 MiB
    local hard_max=134217728    # 128 MiB

    [ "$ram_cap" -lt "$min_cap" ] && ram_cap="$min_cap"
    [ "$ram_cap" -gt "$hard_max" ] && ram_cap="$hard_max"

    local target_buf=33554432   # 默认 32 MiB

    case "$mode" in
        balanced)
            if [ "$MEM_TOTAL_MB" -le 600 ]; then
                target_buf=16777216     # <=512M 机器: 16 MiB
            elif [ "$MEM_TOTAL_MB" -le 1200 ]; then
                target_buf=33554432     # 1G 机器: 32 MiB
            else
                target_buf=67108864     # >=2G 机器: 64 MiB
            fi
            CALC_DEF_RMEM=262144
            CALC_DEF_WMEM=262144
            CALC_UDP_MIN=16384
            CALC_BACKLOG=16384
            CALC_BUDGET=600
            ;;
        bdp)
            # BDP (Bytes) = BW (Mbps) * RTT (ms) * 125
            # 预留 2 倍 BDP 吸收 BBR 探测突发与丢包重传窗口
            local bdp_bytes=$(( bw_mbps * rtt_ms * 125 ))
            target_buf=$(( bdp_bytes * 2 ))
            [ "$target_buf" -lt 8388608 ] && target_buf=8388608
            [ "$target_buf" -gt "$ram_cap" ] && target_buf="$ram_cap"
            # 按 4096 字节对齐
            target_buf=$(( (target_buf / 4096) * 4096 ))
            CALC_DEF_RMEM=262144
            CALC_DEF_WMEM=262144
            CALC_UDP_MIN=16384
            CALC_BACKLOG=32768
            CALC_BUDGET=600
            ;;
        udp)
            if [ "$MEM_TOTAL_MB" -le 600 ]; then
                target_buf=25165824     # 24 MiB
                CALC_DEF_RMEM=524288    # 512 KiB
                CALC_DEF_WMEM=524288
            elif [ "$MEM_TOTAL_MB" -le 1200 ]; then
                target_buf=33554432     # 32 MiB
                CALC_DEF_RMEM=1048576   # 1 MiB
                CALC_DEF_WMEM=1048576
            else
                target_buf=67108864     # 64 MiB
                CALC_DEF_RMEM=1048576   # 1 MiB
                CALC_DEF_WMEM=1048576
            fi
            [ "$target_buf" -gt "$ram_cap" ] && target_buf="$ram_cap"
            CALC_UDP_MIN=32768
            CALC_BACKLOG=32768
            CALC_BUDGET=800
            ;;
    esac

    CALC_MAX_BUF="$target_buf"

    # 计算全局 TCP / UDP 协议栈内存水位 (单位: 内存页 PAGE_SIZE，兼容 4K 与 ARM64 64K 页)
    local total_pages=$(( ram_bytes / PAGE_SIZE ))
    local low_pages=$(( total_pages * 20 / 100 ))
    local pressure_pages=$(( total_pages * 35 / 100 ))
    local high_pages=$(( total_pages * 50 / 100 ))
    [ "$low_pages" -lt 4096 ] && low_pages=4096
    [ "$pressure_pages" -lt 8192 ] && pressure_pages=8192
    [ "$high_pages" -lt 16384 ] && high_pages=16384

    CALC_TCP_MEM="${low_pages} ${pressure_pages} ${high_pages}"
    CALC_UDP_MEM="${low_pages} ${pressure_pages} ${high_pages}"
}

# 安全写入 sysctl 键值（自动忽略当前内核不支持或容器只读的键，杜绝 sysctl 报错）
append_sysctl_if_supported() {
    local file="$1"
    local key="$2"
    local val="$3"
    if sysctl_writable "$key"; then
        printf '%-48s = %s\n' "$key" "$val" >> "$file"
    fi
}

# ============================= 核心协议栈调优写入 =============================
apply_network_profile() {
    local profile="$1"            # balanced | bdp | udp
    local req_qdisc="${2:-}"      # 可选指定 fq / cake / fq_codel / fq_pie
    local bw_mbps="${3:-1000}"
    local rtt_ms="${4:-150}"

    require_root
    ensure_runtime_tools
    ensure_initial_backup

    if [ "$IS_CONTAINER" -eq 1 ] && ! sysctl_writable "net.ipv4.tcp_rmem"; then
        log_err "检测到受限容器虚拟化 (${VIRT_TYPE})，宿主机已锁定 /proc/sys/net 为只读，无法修改内核网络参数。"
        return 1
    fi

    calculate_buffers "$profile" "$bw_mbps" "$rtt_ms"

    # 选择并验证拥塞控制与队列调度
    local cc="bbr"
    if ! ensure_bbr_available; then
        cc="$(read_sysctl net.ipv4.tcp_congestion_control)"
    fi

    local qdisc="$req_qdisc"
    if [ -z "$qdisc" ]; then
        if [ "$profile" = "udp" ]; then
            if ensure_qdisc_available "cake" 0; then
                qdisc="cake"
            else
                qdisc="fq"
            fi
        else
            qdisc="fq"
        fi
    fi

    if ! ensure_qdisc_available "$qdisc" 1; then
        log_warn "当前内核不支持队列算法 '${qdisc}'，自动回退至 'fq'。"
        if ensure_qdisc_available "fq" 0; then
            qdisc="fq"
        else
            qdisc="fq_codel"
        fi
    fi

    local extra_mods=("sch_${qdisc}")
    persist_kernel_modules "${extra_mods[@]}"

    mkdir -p /etc/sysctl.d "$STATE_DIR"
    cat > "$SYSCTL_MAIN" <<EOF
# ==============================================================================
# Managed by net-tune.sh (v${SCRIPT_VERSION})
# Profile : ${profile} (RAM: ${MEM_TOTAL_MB} MiB, Cores: ${CPU_CORES})
# Updated : $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================================

EOF

    # 1. 拥塞控制与队列调度
    printf '# --- 1. 拥塞控制与队列调度 ---\n' >> "$SYSCTL_MAIN"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.core.default_qdisc" "$qdisc"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_congestion_control" "$cc"
    printf '\n' >> "$SYSCTL_MAIN"

    # 2. TCP / UDP 缓冲区与水位
    printf '# --- 2. TCP / UDP 缓冲区 (BDP 与内存保护自适应) ---\n' >> "$SYSCTL_MAIN"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.core.rmem_max" "$CALC_MAX_BUF"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.core.wmem_max" "$CALC_MAX_BUF"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.core.rmem_default" "$CALC_DEF_RMEM"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.core.wmem_default" "$CALC_DEF_WMEM"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.core.optmem_max" "262144"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_rmem" "4096 87380 ${CALC_MAX_BUF}"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_wmem" "4096 65536 ${CALC_MAX_BUF}"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_mem" "$CALC_TCP_MEM"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.udp_mem" "$CALC_UDP_MEM"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.udp_rmem_min" "$CALC_UDP_MIN"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.udp_wmem_min" "$CALC_UDP_MIN"
    printf '\n' >> "$SYSCTL_MAIN"

    # 3. 队列深度与高并发连接池
    printf '# --- 3. 协议栈队列与本地端口池 ---\n' >> "$SYSCTL_MAIN"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.core.somaxconn" "65535"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.core.netdev_max_backlog" "$CALC_BACKLOG"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.core.netdev_budget" "$CALC_BUDGET"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.core.netdev_budget_usecs" "$CALC_BUDGET_USECS"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_max_syn_backlog" "32768"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_max_tw_buckets" "262144"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.ip_local_port_range" "10240 65535"
    printf '\n' >> "$SYSCTL_MAIN"

    # 4. TCP 握手、保活与低延迟优化
    printf '# --- 4. TCP 传输低延迟优化 ---\n' >> "$SYSCTL_MAIN"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_fastopen" "3"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_slow_start_after_idle" "0"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_mtu_probing" "1"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_tw_reuse" "1"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_fin_timeout" "15"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_keepalive_time" "600"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_keepalive_intvl" "30"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_keepalive_probes" "5"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_syn_retries" "3"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_synack_retries" "3"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_retries2" "8"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_sack" "1"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_dsack" "1"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_window_scaling" "1"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_timestamps" "1"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_ecn" "0"
    append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_notsent_lowat" "131072"
    printf '\n' >> "$SYSCTL_MAIN"

    # 5. 内核级文件描述符上限
    printf '# --- 5. 内核文件句柄上限 ---\n' >> "$SYSCTL_MAIN"
    append_sysctl_if_supported "$SYSCTL_MAIN" "fs.file-max" "$TARGET_NOFILE"
    append_sysctl_if_supported "$SYSCTL_MAIN" "fs.nr_open" "$TARGET_NOFILE"
    printf '\n' >> "$SYSCTL_MAIN"

    # 6. 若当前系统已启用 nf_conntrack，自动按内存扩容防丢包（未启用则不强行加载以免增加额外开销）
    if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
        append_conntrack_sysctl "$SYSCTL_MAIN"
    fi

    # 立即应用配置并切换实时网卡 qdisc
    sysctl -e -p "$SYSCTL_MAIN" >/dev/null 2>&1 || true
    apply_live_qdisc "$qdisc"

    # 记录状态供启动脚本及状态栏展示
    cat > "$STATE_FILE" <<EOF
ACTIVE_PROFILE="${profile}"
ACTIVE_QDISC="${qdisc}"
ACTIVE_CC="${cc}"
ACTIVE_MAX_BUF="${CALC_MAX_BUF}"
UPDATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

    log_ok "协议栈调优已生效 [模式: ${profile} | 算法: ${cc} + ${qdisc} | 单连接最大缓冲: $(human_bytes "$CALC_MAX_BUF")]"
}

# ============================= Conntrack 专项调优 =============================
calc_conntrack_max() {
    if [ "$MEM_TOTAL_MB" -le 600 ]; then
        printf '65536'
    elif [ "$MEM_TOTAL_MB" -le 1200 ]; then
        printf '131072'
    elif [ "$MEM_TOTAL_MB" -le 2500 ]; then
        printf '262144'
    elif [ "$MEM_TOTAL_MB" -le 5000 ]; then
        printf '524288'
    else
        printf '1048576'
    fi
}

append_conntrack_sysctl() {
    local target_file="$1"
    local ct_max
    ct_max="$(calc_conntrack_max)"
    local hash_sz=$(( ct_max / 4 ))

    printf '# --- Conntrack 连接跟踪表优化 ---\n' >> "$target_file"
    append_sysctl_if_supported "$target_file" "net.netfilter.nf_conntrack_max" "$ct_max"
    append_sysctl_if_supported "$target_file" "net.netfilter.nf_conntrack_tcp_timeout_established" "7200"
    append_sysctl_if_supported "$target_file" "net.netfilter.nf_conntrack_tcp_timeout_time_wait" "30"
    append_sysctl_if_supported "$target_file" "net.netfilter.nf_conntrack_tcp_timeout_close_wait" "15"
    append_sysctl_if_supported "$target_file" "net.netfilter.nf_conntrack_tcp_timeout_fin_wait" "30"
    append_sysctl_if_supported "$target_file" "net.netfilter.nf_conntrack_udp_timeout" "30"
    append_sysctl_if_supported "$target_file" "net.netfilter.nf_conntrack_udp_timeout_stream" "120"
    printf '\n' >> "$target_file"

    # 运行时动态调整哈希桶大小并持久化到 modprobe.d
    if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
        printf '%s' "$hash_sz" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    fi
    mkdir -p /etc/modprobe.d
    cat > "$MODPROBE_CONF" <<EOF
# Managed by net-tune.sh
options nf_conntrack hashsize=${hash_sz}
EOF
}

tune_conntrack_explicit() {
    require_root
    ensure_initial_backup

    modprobe nf_conntrack >/dev/null 2>&1 || true
    if [ ! -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
        log_warn "当前内核未提供 nf_conntrack 模块（纯无状态转发无需此模块）。"
        return 1
    fi

    persist_kernel_modules "nf_conntrack"

    local ct_file="/etc/sysctl.d/98-net-tune-conntrack.conf"
    cat > "$ct_file" <<EOF
# Managed by net-tune.sh — Conntrack Explicit Tuning
EOF
    append_conntrack_sysctl "$ct_file"
    sysctl -e -p "$ct_file" >/dev/null 2>&1 || true

    local ct_max
    ct_max="$(read_sysctl net.netfilter.nf_conntrack_max)"
    log_ok "Conntrack 连接跟踪调优完成 [最大跟踪连接数: ${ct_max}]"
}

# ============================= 系统句柄与网卡 RPS/RFS =========================
apply_ulimit_tuning() {
    require_root
    ensure_initial_backup

    # 1. 内核级上限确保写入
    sysctl -w "fs.file-max=${TARGET_NOFILE}" >/dev/null 2>&1 || true
    sysctl -w "fs.nr_open=${TARGET_NOFILE}" >/dev/null 2>&1 || true

    # 2. PAM / limits.d
    mkdir -p /etc/security/limits.d
    cat > "$LIMITS_CONF" <<EOF
# Managed by net-tune.sh
*               soft    nofile          ${TARGET_NOFILE}
*               hard    nofile          ${TARGET_NOFILE}
root            soft    nofile          ${TARGET_NOFILE}
root            hard    nofile          ${TARGET_NOFILE}
*               soft    nproc           unlimited
*               hard    nproc           unlimited
EOF

    # 3. Systemd 与 OpenRC 差异化适配
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
        cat > "$SYSTEMD_SYS_CONF" <<EOF
[Manager]
DefaultLimitNOFILE=${TARGET_NOFILE}
EOF
        cat > "$SYSTEMD_USR_CONF" <<EOF
[Manager]
DefaultLimitNOFILE=${TARGET_NOFILE}
EOF
        systemctl daemon-reexec >/dev/null 2>&1 || systemctl daemon-reload >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        if [ -f /etc/rc.conf ]; then
            backup_file_once /etc/rc.conf
            if grep -qE '^[#[:space:]]*rc_ulimit=' /etc/rc.conf; then
                sed -i "s|^[#[:space:]]*rc_ulimit=.*|rc_ulimit=\"-n ${TARGET_NOFILE}\"|" /etc/rc.conf
            else
                printf '\n# Managed by net-tune.sh\nrc_ulimit="-n %s"\n' "$TARGET_NOFILE" >> /etc/rc.conf
            fi
        fi
    fi

    # 4. 交互式 Shell 环境立即生效脚本
    mkdir -p /etc/profile.d
    cat > "$OPENRC_ULIMIT_SH" <<EOF
# Managed by net-tune.sh
ulimit -SHn ${TARGET_NOFILE} 2>/dev/null || true
EOF
    chmod 0644 "$OPENRC_ULIMIT_SH"
    ulimit -SHn "$TARGET_NOFILE" 2>/dev/null || true

    log_ok "全局文件句柄上限已调优至 ${TARGET_NOFILE} (兼容 ${INIT_SYSTEM} 服务与交互会话)"
}

# 生成任意核心数的标准 Linux 十六进制 CPU 位图 (支持 >64 核无溢出)
generate_cpu_bitmask() {
    local cores="$1"
    local rem="$cores"
    local mask=""
    while [ "$rem" -gt 32 ]; do
        if [ -z "$mask" ]; then
            mask="ffffffff"
        else
            mask="ffffffff,${mask}"
        fi
        rem=$(( rem - 32 ))
    done
    if [ "$rem" -gt 0 ]; then
        local top_val=0
        if [ "$rem" -eq 32 ]; then
            top_val=4294967295
        else
            top_val=$(( (1 << rem) - 1 ))
        fi
        local top_hex
        top_hex="$(printf '%x' "$top_val")"
        if [ -z "$mask" ]; then
            mask="$top_hex"
        else
            mask="${top_hex},${mask}"
        fi
    fi
    printf '%s' "${mask:-1}"
}

apply_nic_tuning() {
    require_root
    ensure_runtime_tools

    if [ -z "$PRIMARY_NIC" ] || [ ! -d "/sys/class/net/${PRIMARY_NIC}" ]; then
        log_warn "未检测到有效主网卡，跳过网卡队列优化。"
        return 0
    fi

    local cur_qdisc
    cur_qdisc="$(read_sysctl net.core.default_qdisc)"
    [ "$cur_qdisc" = "N/A" ] && cur_qdisc="fq"

    local cpu_mask
    cpu_mask="$(generate_cpu_bitmask "$CPU_CORES")"

    local hash_sz=""
    if [ -e /sys/module/nf_conntrack/parameters/hashsize ]; then
        local ct_max
        ct_max="$(calc_conntrack_max)"
        hash_sz=$(( ct_max / 4 ))
    fi

    mkdir -p "$STATE_DIR"
    cat > "$NIC_SCRIPT" <<EOF
#!/bin/sh
# Managed by net-tune.sh — Boot-time NIC & Runtime Queue Optimizer
NIC="${PRIMARY_NIC}"
QDISC="${cur_qdisc}"
CORES="${CPU_CORES}"
CPU_MASK="${cpu_mask}"
CT_HASHSIZE="${hash_sz}"

if [ -d "/sys/class/net/\${NIC}" ]; then
    command -v ip >/dev/null 2>&1 && ip link set dev "\${NIC}" txqueuelen 10000 2>/dev/null || true
    command -v tc >/dev/null 2>&1 && tc qdisc replace dev "\${NIC}" root "\${QDISC}" 2>/dev/null || true

    if [ "\${CORES}" -gt 1 ] && [ -d "/sys/class/net/\${NIC}/queues" ]; then
        rx_count=0
        for q in /sys/class/net/"\${NIC}"/queues/rx-*; do
            [ -d "\$q" ] && rx_count=\$(( rx_count + 1 ))
        done
        if [ "\${rx_count}" -gt 0 ]; then
            total_flows=32768
            per_q=\$(( total_flows / rx_count ))
            [ -w /proc/sys/net/core/rps_sock_flow_entries ] && echo "\${total_flows}" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
            for q in /sys/class/net/"\${NIC}"/queues/rx-*; do
                [ -w "\$q/rps_cpus" ] && echo "\${CPU_MASK}" > "\$q/rps_cpus" 2>/dev/null || true
                [ -w "\$q/rps_flow_cnt" ] && echo "\${per_q}" > "\$q/rps_flow_cnt" 2>/dev/null || true
            done
        fi
    fi
fi

if [ -n "\${CT_HASHSIZE}" ] && [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
    echo "\${CT_HASHSIZE}" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
fi
exit 0
EOF
    chmod 0755 "$NIC_SCRIPT"
    "$NIC_SCRIPT"

    # 注册开机自启以保持 txqueuelen / tc qdisc / RPS 在重启后持续生效
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        cat > "$SYSTEMD_NIC_SVC" <<EOF
[Unit]
Description=Network NIC Queue & RPS/RFS Tuning (net-tune.sh)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${NIC_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable net-tune-nic.service >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        mkdir -p /etc/local.d
        ln -sf "$NIC_SCRIPT" "$OPENRC_NIC_START"
        chmod 0755 "$OPENRC_NIC_START" 2>/dev/null || true
        rc-update add local default >/dev/null 2>&1 || true
    fi

    if [ "$CPU_CORES" -gt 1 ]; then
        log_ok "主网卡 (${PRIMARY_NIC}) 已优化: txqueuelen=10000, qdisc=${cur_qdisc}, 多核 RPS/RFS (掩码 0x${cpu_mask}) 已激活"
    else
        log_ok "主网卡 (${PRIMARY_NIC}) 已优化: txqueuelen=10000, qdisc=${cur_qdisc} (单核环境自动跳过 RPS)"
    fi
}

# ============================= 周边辅助工具集 =================================
# 1. 单独切换拥塞控制与队列调度
switch_cc_qdisc() {
    local cc="$1"
    local qdisc="$2"
    require_root
    ensure_initial_backup

    modprobe "tcp_${cc}" >/dev/null 2>&1 || true
    local avail
    avail="$(read_sysctl net.ipv4.tcp_available_congestion_control)"
    case " $avail " in
        *" ${cc} "*) ;;
        *)
            log_err "当前内核不支持拥塞控制算法 '${cc}' (可用: ${avail})"
            return 1
            ;;
    esac

    if ! ensure_qdisc_available "$qdisc" 1; then
        log_err "当前内核不支持队列调度算法 '${qdisc}'"
        return 1
    fi

    persist_kernel_modules "tcp_${cc}" "sch_${qdisc}"

    if [ -f "$SYSCTL_MAIN" ]; then
        if grep -q '^net\.core\.default_qdisc' "$SYSCTL_MAIN"; then
            sed -i "s|^net\.core\.default_qdisc.*|net.core.default_qdisc                           = ${qdisc}|" "$SYSCTL_MAIN"
        else
            append_sysctl_if_supported "$SYSCTL_MAIN" "net.core.default_qdisc" "$qdisc"
        fi
        if grep -q '^net\.ipv4\.tcp_congestion_control' "$SYSCTL_MAIN"; then
            sed -i "s|^net\.ipv4\.tcp_congestion_control.*|net.ipv4.tcp_congestion_control                  = ${cc}|" "$SYSCTL_MAIN"
        else
            append_sysctl_if_supported "$SYSCTL_MAIN" "net.ipv4.tcp_congestion_control" "$cc"
        fi
        sysctl -e -p "$SYSCTL_MAIN" >/dev/null 2>&1 || true
    else
        mkdir -p /etc/sysctl.d
        cat > "$SYSCTL_MAIN" <<EOF
# Managed by net-tune.sh
net.core.default_qdisc = ${qdisc}
net.ipv4.tcp_congestion_control = ${cc}
EOF
        sysctl -e -p "$SYSCTL_MAIN" >/dev/null 2>&1 || true
    fi

    apply_live_qdisc "$qdisc"
    [ -f "$NIC_SCRIPT" ] && apply_nic_tuning >/dev/null 2>&1 || true
    log_ok "已切换拥塞控制与队列调度为: ${cc} + ${qdisc}"
}

# 2. IPv4 / IPv6 流量转发开关
set_ip_forward() {
    local enable="$1"   # 1 | 0
    require_root
    ensure_initial_backup

    mkdir -p /etc/sysctl.d
    cat > "$SYSCTL_FORWARD" <<EOF
# Managed by net-tune.sh — IPv4 / IPv6 Forwarding
EOF
    append_sysctl_if_supported "$SYSCTL_FORWARD" "net.ipv4.ip_forward" "$enable"
    append_sysctl_if_supported "$SYSCTL_FORWARD" "net.ipv6.conf.all.forwarding" "$enable"
    append_sysctl_if_supported "$SYSCTL_FORWARD" "net.ipv6.conf.default.forwarding" "$enable"
    sysctl -e -p "$SYSCTL_FORWARD" >/dev/null 2>&1 || true

    if [ "$enable" = "1" ]; then
        log_ok "已开启 IPv4 & IPv6 内核流量转发 (ip_forward = 1)"
    else
        log_ok "已关闭 IPv4 & IPv6 内核流量转发 (ip_forward = 0)"
    fi
}

# 3. IPv4 / IPv6 出站优先级切换 (/etc/gai.conf)
get_ip_preference() {
    if [ "$IS_MUSL" -eq 1 ]; then
        printf '双栈默认 (Alpine musl 不读取 gai.conf)'
        return
    fi
    if [ -f /etc/gai.conf ] && grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' /etc/gai.conf; then
        printf 'IPv4 优先'
    else
        printf 'IPv6 优先 (系统默认)'
    fi
}

set_ip_preference() {
    local pref="$1"     # ipv4 | ipv6
    require_root
    ensure_initial_backup

    if [ "$IS_MUSL" -eq 1 ]; then
        log_warn "检测到当前系统使用 musl libc (Alpine Linux)：musl 的 DNS 解析器不读取 /etc/gai.conf。"
        log_info "如需在 Alpine 强制仅走 IPv4 出站，可在代理软件侧配置路由策略或禁用网卡 IPv6。"
        return 0
    fi

    backup_file_once /etc/gai.conf
    touch /etc/gai.conf

    # 先清理已有的未注释 ::ffff:0:0/96 规则
    sed -i '/^[[:space:]]*precedence[[:space:]][[:space:]]*::ffff:0:0\/96[[:space:]][[:space:]]*100/d' /etc/gai.conf

    if [ "$pref" = "ipv4" ]; then
        printf 'precedence ::ffff:0:0/96  100\n' >> /etc/gai.conf
        log_ok "出站连接优先级已设为: IPv4 优先 (/etc/gai.conf)"
    else
        log_ok "出站连接优先级已恢复: IPv6 优先 (/etc/gai.conf)"
    fi
}

# 4. Swap 虚拟内存与 Swappiness 管理
create_swap_file() {
    local size_mb="$1"
    require_root
    ensure_initial_backup

    if [ "$IS_CONTAINER" -eq 1 ]; then
        log_err "容器环境 (${VIRT_TYPE}) 不允许挂载独立 Swap 文件。"
        return 1
    fi

    if ! printf '%s' "$size_mb" | grep -qE '^[0-9]+$' || [ "$size_mb" -lt 128 ]; then
        log_err "请输入有效的 Swap 大小 (>= 128 MiB)。"
        return 1
    fi

    local avail_mb
    avail_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -n "$avail_mb" ] && [ "$avail_mb" -lt $(( size_mb + 512 )) ]; then
        log_err "根目录剩余磁盘空间不足 (当前剩余 ${avail_mb} MiB，至少需预留 $(( size_mb + 512 )) MiB)。"
        return 1
    fi

    local swapfile="/swapfile"
    if grep -q "^${swapfile}[[:space:]]" /proc/swaps 2>/dev/null; then
        log_info "正在卸载旧的 ${swapfile}..."
        swapoff "$swapfile" || true
    fi
    rm -f "$swapfile"

    local fstype
    fstype="$(df -PT / 2>/dev/null | awk 'NR==2 {print $2}')"
    log_info "正在创建 ${size_mb} MiB Swap 文件 (文件系统: ${fstype:-unknown})，请稍候..."

    if [ "$fstype" = "btrfs" ] && command -v btrfs >/dev/null 2>&1 && btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
        btrfs filesystem mkswapfile --size "${size_mb}m" "$swapfile"
    else
        if [ "$fstype" = "btrfs" ] && command -v chattr >/dev/null 2>&1; then
            touch "$swapfile"
            chattr +C "$swapfile" 2>/dev/null || true
        fi
        # 使用 dd 保证 XFS / Ext4 / BusyBox 全平台兼容，避免 fallocate 空洞导致 swapon 失败
        if dd --help 2>&1 | grep -q 'status='; then
            dd if=/dev/zero of="$swapfile" bs=1M count="$size_mb" status=progress
        else
            dd if=/dev/zero of="$swapfile" bs=1M count="$size_mb"
        fi
        chmod 0600 "$swapfile"
        mkswap "$swapfile" >/dev/null
    fi

    chmod 0600 "$swapfile"
    if ! swapon "$swapfile"; then
        rm -f "$swapfile"
        log_err "挂载 Swap 失败，已自动清理临时文件。"
        return 1
    fi

    backup_file_once /etc/fstab
    sed -i "\|^${swapfile}[[:space:]]|d" /etc/fstab
    printf '%s none swap sw 0 0\n' "$swapfile" >> /etc/fstab

    mkdir -p /etc/sysctl.d
    cat > "$SYSCTL_SWAP" <<EOF
# Managed by net-tune.sh — Swap & Memory Pressure Tuning
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    sysctl -e -p "$SYSCTL_SWAP" >/dev/null 2>&1 || true

    log_ok "Swap (${size_mb} MiB) 已启用并写入开机挂载，vm.swappiness 已调优为 10"
}

remove_swap_file() {
    require_root
    local swapfile="/swapfile"
    if grep -q "^${swapfile}[[:space:]]" /proc/swaps 2>/dev/null; then
        swapoff "$swapfile" || true
    fi
    rm -f "$swapfile" "$SYSCTL_SWAP"
    [ -f /etc/fstab ] && sed -i "\|^${swapfile}[[:space:]]|d" /etc/fstab
    reload_all_sysctl
    log_ok "已移除 /swapfile 及关联配置"
}

# ============================= 一键回滚还原 ===================================
rollback_all() {
    require_root
    log_info "正在清理所有 net-tune 调优配置并恢复备份..."

    # 1. 移除所有独立 drop-in 文件与启动项
    rm -f \
        "$SYSCTL_MAIN" \
        "$SYSCTL_FORWARD" \
        "$SYSCTL_SWAP" \
        "/etc/sysctl.d/98-net-tune-conntrack.conf" \
        "$MODULES_CONF" \
        "$MODPROBE_CONF" \
        "$LIMITS_CONF" \
        "$SYSTEMD_SYS_CONF" \
        "$SYSTEMD_USR_CONF" \
        "$OPENRC_ULIMIT_SH" \
        "$OPENRC_NIC_START" \
        "$NIC_SCRIPT" \
        "$STATE_FILE"

    if [ "$INIT_SYSTEM" = "systemd" ] && [ -f "$SYSTEMD_NIC_SVC" ]; then
        systemctl disable net-tune-nic.service >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_NIC_SVC"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl daemon-reexec >/dev/null 2>&1 || true
    fi

    # 2. 还原修改过的系统配置文件 (/etc/gai.conf, /etc/rc.conf)
    if [ -f "${BACKUP_FILES_DIR}/gai.conf.orig" ]; then
        cp -a "${BACKUP_FILES_DIR}/gai.conf.orig" /etc/gai.conf
    fi
    if [ -f "${BACKUP_FILES_DIR}/rc.conf.orig" ]; then
        cp -a "${BACKUP_FILES_DIR}/rc.conf.orig" /etc/rc.conf
    fi

    # 3. 恢复初始 sysctl 快照值，并重新加载系统原厂 sysctl
    if [ -f "$SYSCTL_SNAPSHOT" ]; then
        while IFS='=' read -r key val; do
            [ -z "$key" ] && continue
            sysctl -w "${key}=${val}" >/dev/null 2>&1 || true
        done < "$SYSCTL_SNAPSHOT"
    fi
    reload_all_sysctl

    # 4. 恢复主网卡默认 qdisc、发送队列长度与 RPS 状态
    local def_qdisc
    def_qdisc="$(read_sysctl net.core.default_qdisc)"
    [ "$def_qdisc" != "N/A" ] && apply_live_qdisc "$def_qdisc"
    if [ -n "$PRIMARY_NIC" ] && [ -d "/sys/class/net/${PRIMARY_NIC}" ]; then
        command -v ip >/dev/null 2>&1 && ip link set dev "$PRIMARY_NIC" txqueuelen 1000 2>/dev/null || true
        if [ -d "/sys/class/net/${PRIMARY_NIC}/queues" ]; then
            local q
            for q in /sys/class/net/"${PRIMARY_NIC}"/queues/rx-*; do
                [ -w "$q/rps_cpus" ] && printf '0' > "$q/rps_cpus" 2>/dev/null || true
                [ -w "$q/rps_flow_cnt" ] && printf '0' > "$q/rps_flow_cnt" 2>/dev/null || true
            done
        fi
    fi
    [ -w /proc/sys/net/core/rps_sock_flow_entries ] && printf '0' > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

    log_ok "所有网络调优项已回滚至初始状态（如修改过服务句柄上限，重启机器或重启对应服务后彻底还原）。"
}

# ============================= 状态仪表盘与体检 ===============================
get_swap_summary() {
    if [ -r /proc/meminfo ]; then
        local total_kb free_kb used_mb total_mb
        total_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
        free_kb="$(awk '/^SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
        if [ "${total_kb:-0}" -eq 0 ]; then
            printf '未启用 (swappiness=%s)' "$(read_sysctl vm.swappiness)"
        else
            total_mb=$(( total_kb / 1024 ))
            used_mb=$(( (total_kb - free_kb) / 1024 ))
            printf '%s / %s MiB (swappiness=%s)' "$used_mb" "$total_mb" "$(read_sysctl vm.swappiness)"
        fi
    else
        printf 'N/A'
    fi
}

get_conntrack_summary() {
    if [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
        local cur max
        cur="$(read_sysctl net.netfilter.nf_conntrack_count)"
        max="$(read_sysctl net.netfilter.nf_conntrack_max)"
        printf '%s / %s' "$cur" "$max"
    else
        printf '未加载 (无状态低开销)'
    fi
}

get_live_nic_qdisc() {
    if [ -n "$PRIMARY_NIC" ] && command -v tc >/dev/null 2>&1; then
        tc qdisc show dev "$PRIMARY_NIC" 2>/dev/null | awk 'NR==1 {print $2}'
    else
        printf 'N/A'
    fi
}

show_dashboard() {
    local detailed="${1:-0}"

    local cc qdisc live_qdisc rmem_max wmem_max tcp_rmem tcp_wmem udp_min
    local tfo slow_idle lowat file_max ulimit_n ip4_fwd ip6_fwd active_prof
    cc="$(read_sysctl net.ipv4.tcp_congestion_control)"
    qdisc="$(read_sysctl net.core.default_qdisc)"
    live_qdisc="$(get_live_nic_qdisc)"
    rmem_max="$(read_sysctl net.core.rmem_max)"
    wmem_max="$(read_sysctl net.core.wmem_max)"
    tcp_rmem="$(read_sysctl net.ipv4.tcp_rmem)"
    tcp_wmem="$(read_sysctl net.ipv4.tcp_wmem)"
    udp_min="$(read_sysctl net.ipv4.udp_rmem_min)"
    tfo="$(read_sysctl net.ipv4.tcp_fastopen)"
    slow_idle="$(read_sysctl net.ipv4.tcp_slow_start_after_idle)"
    lowat="$(read_sysctl net.ipv4.tcp_notsent_lowat)"
    file_max="$(read_sysctl fs.file-max)"
    ulimit_n="$(ulimit -n 2>/dev/null || echo N/A)"
    ip4_fwd="$(read_sysctl net.ipv4.ip_forward)"
    ip6_fwd="$(read_sysctl net.ipv6.conf.all.forwarding)"

    active_prof="未应用"
    if [ -r "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        active_prof="${ACTIVE_PROFILE:-已调优} (${UPDATED_AT:-})"
    fi

    local rmem_h="$rmem_max"
    printf '%s' "$rmem_max" | grep -qE '^[0-9]+$' && rmem_h="$(human_bytes "$rmem_max")"
    local wmem_h="$wmem_max"
    printf '%s' "$wmem_max" | grep -qE '^[0-9]+$' && wmem_h="$(human_bytes "$wmem_max")"

    printf '\n%s======================================================================%s\n' "${C_BLUE}${C_BOLD}" "${C_RESET}"
    printf ' %sVPS 网络与高并发调优面板 (net-tune v%s)%s\n' "${C_BOLD}" "${SCRIPT_VERSION}" "${C_RESET}"
    printf '%s======================================================================%s\n' "${C_BLUE}${C_BOLD}" "${C_RESET}"
    printf ' %-16s : %s (%s / %s)\n' "系统与内核" "${OS_PRETTY}" "${KERNEL_REL}" "${ARCH}"
    printf ' %-16s : %s | Init: %s | %s 核 / %s MiB 内存\n' "硬件与虚拟化" "${VIRT_TYPE}" "${INIT_SYSTEM}" "${CPU_CORES}" "${MEM_TOTAL_MB}"
    printf ' %-16s : %s | 实时队列: %s\n' "主出站网卡" "${PRIMARY_NIC:-未检测到}" "${live_qdisc:-N/A}"
    print_hr
    printf ' %-16s : %s%s + %s%s\n' "拥塞控制 + 队列" "${C_GREEN}${C_BOLD}" "${cc}" "${qdisc}" "${C_RESET}"
    printf ' %-16s : 读 %s / 写 %s | UDP min: %s B\n' "最大 Socket 缓冲" "${rmem_h}" "${wmem_h}" "${udp_min}"
    printf ' %-16s : TFO=%s | 空闲慢启动=%s | notsent_lowat=%s\n' "TCP 传输特性" "${tfo}" "${slow_idle}" "${lowat}"
    printf ' %-16s : file-max=%s | 当前会话 ulimit -n=%s\n' "文件句柄上限" "${file_max}" "${ulimit_n}"
    printf ' %-16s : %s\n' "Conntrack 跟踪表" "$(get_conntrack_summary)"
    printf ' %-16s : IPv4=%s, IPv6=%s | 出站: %s\n' "IP 转发与优先级" "${ip4_fwd}" "${ip6_fwd}" "$(get_ip_preference)"
    printf ' %-16s : %s\n' "Swap 虚拟内存" "$(get_swap_summary)"
    printf ' %-16s : %s%s%s\n' "当前调优档案" "${C_CYAN}" "${active_prof}" "${C_RESET}"
    printf '%s======================================================================%s\n' "${C_BLUE}${C_BOLD}" "${C_RESET}"

    if [ "$detailed" -eq 1 ]; then
        printf '\n%s[核心内核参数明细]%s\n' "${C_BOLD}" "${C_RESET}"
        printf '  net.ipv4.tcp_available_congestion_control = %s\n' "$(read_sysctl net.ipv4.tcp_available_congestion_control)"
        printf '  net.ipv4.tcp_rmem                         = %s\n' "$tcp_rmem"
        printf '  net.ipv4.tcp_wmem                         = %s\n' "$tcp_wmem"
        printf '  net.ipv4.tcp_mem                          = %s (页大小: %s B)\n' "$(read_sysctl net.ipv4.tcp_mem)" "$PAGE_SIZE"
        printf '  net.ipv4.udp_mem                          = %s\n' "$(read_sysctl net.ipv4.udp_mem)"
        printf '  net.core.somaxconn                        = %s\n' "$(read_sysctl net.core.somaxconn)"
        printf '  net.core.netdev_max_backlog               = %s\n' "$(read_sysctl net.core.netdev_max_backlog)"
        printf '  net.ipv4.tcp_max_syn_backlog              = %s\n' "$(read_sysctl net.ipv4.tcp_max_syn_backlog)"
        printf '  net.ipv4.ip_local_port_range              = %s\n' "$(read_sysctl net.ipv4.ip_local_port_range)"
        printf '  net.ipv4.tcp_mtu_probing                  = %s\n' "$(read_sysctl net.ipv4.tcp_mtu_probing)"
        printf '  net.ipv4.tcp_tw_reuse                     = %s\n' "$(read_sysctl net.ipv4.tcp_tw_reuse)"
        printf '  net.ipv4.tcp_fin_timeout                  = %s\n' "$(read_sysctl net.ipv4.tcp_fin_timeout)"
        printf '  net.ipv4.tcp_ecn                          = %s\n' "$(read_sysctl net.ipv4.tcp_ecn)"
        if [ -n "$PRIMARY_NIC" ] && [ -r "/sys/class/net/${PRIMARY_NIC}/tx_queue_len" ]; then
            printf '  NIC (%s) tx_queue_len                   = %s\n' "$PRIMARY_NIC" "$(cat "/sys/class/net/${PRIMARY_NIC}/tx_queue_len" 2>/dev/null || echo N/A)"
        fi
        printf '\n'
    fi
}

# ============================= 快捷命令安装与自更新 ===========================
fetch_url_to_file() {
    local url="$1"
    local dst="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 10 "$url" -o "$dst"
        return $?
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dst" --timeout=10 --tries=2 "$url"
        return $?
    else
        log_info "正在安装 curl..."
        case "$OS_FAMILY" in
            debian)
                DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates >/dev/null 2>&1 || true
                ;;
            rhel)
                dnf install -y -q curl ca-certificates >/dev/null 2>&1 || yum install -y -q curl ca-certificates >/dev/null 2>&1 || true
                ;;
            alpine)
                apk add --no-cache curl ca-certificates >/dev/null 2>&1 || true
                ;;
        esac
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --retry 2 --connect-timeout 10 "$url" -o "$dst"
            return $?
        fi
    fi
    return 1
}

install_cli_command() {
    local quiet="${1:-0}"
    [ "$(id -u)" -ne 0 ] && return 0

    mkdir -p /usr/local/bin

    # 若当前已经是从 /usr/local/bin/net-tune 运行，仅确保 /usr/bin 软链存在（兼容 RHEL sudo secure_path）
    if [ -f "$0" ] && [ "$0" = "$INSTALL_BIN" ]; then
        if [ ! -e "$SYMLINK_BIN" ] && [ -d /usr/bin ]; then
            ln -sf "$INSTALL_BIN" "$SYMLINK_BIN" 2>/dev/null || true
        fi
        [ "$quiet" -eq 0 ] && log_ok "快捷命令已就绪: net-tune (${INSTALL_BIN})"
        return 0
    fi

    local tmp_bin="/usr/local/bin/.net-tune.tmp.$$"
    if [ -f "$0" ] && head -n 1 "$0" 2>/dev/null | grep -q '^#!'; then
        cp -f "$0" "$tmp_bin"
    else
        # 通过 bash <(curl ...) 或 curl ... | bash 运行时，从 GitHub 拉取完整脚本持久化
        if ! fetch_url_to_file "$REPO_RAW_URL" "$tmp_bin"; then
            rm -f "$tmp_bin"
            [ "$quiet" -eq 0 ] && log_warn "无法从 GitHub 下载脚本持久化到 ${INSTALL_BIN}，本次运行不受影响。"
            return 1
        fi
    fi

    if [ -s "$tmp_bin" ] && bash -n "$tmp_bin" >/dev/null 2>&1; then
        chmod 0755 "$tmp_bin"
        mv -f "$tmp_bin" "$INSTALL_BIN"
        if { [ ! -e "$SYMLINK_BIN" ] || [ -L "$SYMLINK_BIN" ]; } && [ -d /usr/bin ]; then
            ln -sf "$INSTALL_BIN" "$SYMLINK_BIN" 2>/dev/null || true
        fi
        [ "$quiet" -eq 0 ] && log_ok "已安装系统全局快捷命令: net-tune (以后直接输入 'net-tune' 或 'sudo net-tune' 即可打开面板)"
        return 0
    else
        rm -f "$tmp_bin"
        [ "$quiet" -eq 0 ] && log_err "校验脚本完整性失败，未覆盖 ${INSTALL_BIN}。"
        return 1
    fi
}

update_cli_command() {
    require_root
    log_info "正在从 GitHub (${REPO_RAW_URL}) 检查并拉取最新版本..."
    local tmp_bin="/usr/local/bin/.net-tune.update.$$"
    if ! fetch_url_to_file "$REPO_RAW_URL" "$tmp_bin"; then
        rm -f "$tmp_bin"
        log_err "下载失败，请检查 VPS 访问 raw.githubusercontent.com 的网络连接。"
        return 1
    fi

    if ! head -n 1 "$tmp_bin" 2>/dev/null | grep -q '^#!' || ! bash -n "$tmp_bin" >/dev/null 2>&1; then
        rm -f "$tmp_bin"
        log_err "下载的文件格式或语法校验未通过，已中止更新。"
        return 1
    fi

    local new_ver
    new_ver="$(sed -n 's/^readonly SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$tmp_bin" | head -n 1)"
    mkdir -p /usr/local/bin
    chmod 0755 "$tmp_bin"
    mv -f "$tmp_bin" "$INSTALL_BIN"
    if { [ ! -e "$SYMLINK_BIN" ] || [ -L "$SYMLINK_BIN" ]; } && [ -d /usr/bin ]; then
        ln -sf "$INSTALL_BIN" "$SYMLINK_BIN" 2>/dev/null || true
    fi
    log_ok "net-tune 已更新至最新版本 (v${new_ver:-unknown}) -> ${INSTALL_BIN}"
}

uninstall_all() {
    require_root
    rollback_all
    rm -f "$INSTALL_BIN"
    [ -L "$SYMLINK_BIN" ] && rm -f "$SYMLINK_BIN"
    rm -rf "$STATE_DIR"
    log_ok "已彻底卸载 net-tune 快捷命令及备份目录 (${STATE_DIR})。"
}

# ============================= 一键组合执行动作 ===============================
run_full_tune() {
    local profile="$1"
    local qdisc="${2:-}"
    local bw="${3:-1000}"
    local rtt="${4:-150}"

    apply_network_profile "$profile" "$qdisc" "$bw" "$rtt"
    apply_ulimit_tuning
    apply_nic_tuning
}

# ============================= 交互式菜单面板 =================================
pause_prompt() {
    printf '\n'
    read -r -p "按回车键返回主菜单..." _ || true
}

menu_bdp_wizard() {
    printf '\n%s>>> 跨国大带宽 BDP 精准计算向导%s\n' "${C_BOLD}" "${C_RESET}"
    local bw rtt qdisc_choice qdisc="fq"
    read -r -p "请输入 VPS 峰值带宽 (Mbps，默认 1000): " bw
    bw="${bw:-1000}"
    if ! printf '%s' "$bw" | grep -qE '^[0-9]+$' || [ "$bw" -lt 1 ]; then
        log_err "带宽输入无效，请输入正整数。"
        return 1
    fi

    read -r -p "请输入到目标客户端的平均延迟 RTT (ms，默认 160): " rtt
    rtt="${rtt:-160}"
    if ! printf '%s' "$rtt" | grep -qE '^[0-9]+$' || [ "$rtt" -lt 1 ]; then
        log_err "延迟输入无效，请输入正整数。"
        return 1
    fi

    read -r -p "选择队列调度算法 [1: fq (默认推荐) / 2: cake]: " qdisc_choice
    [ "${qdisc_choice:-1}" = "2" ] && qdisc="cake"

    local raw_bdp=$(( bw * rtt * 125 ))
    log_info "理论单流 BDP = $(human_bytes "$raw_bdp")，将自动结合 ${MEM_TOTAL_MB} MiB 内存安全边界计算缓冲上限..."
    run_full_tune "bdp" "$qdisc" "$bw" "$rtt"
}

menu_switch_qdisc() {
    printf '\n%s>>> 切换拥塞控制与队列调度组合%s\n' "${C_BOLD}" "${C_RESET}"
    printf '  1) bbr + fq        (推荐：TCP 高吞吐与通用首选)\n'
    printf '  2) bbr + cake      (适合 TCP/UDP 混合突发防缓冲膨胀)\n'
    printf '  3) bbr + fq_pie    (低延迟队列控制)\n'
    printf '  4) bbr + fq_codel  (Linux 传统均衡队列)\n'
    printf '  5) cubic + fq_codel(系统传统默认)\n'
    local c
    read -r -p "请选择 [1-5，回车取消]: " c
    case "${c:-}" in
        1) switch_cc_qdisc "bbr" "fq" ;;
        2) switch_cc_qdisc "bbr" "cake" ;;
        3) switch_cc_qdisc "bbr" "fq_pie" ;;
        4) switch_cc_qdisc "bbr" "fq_codel" ;;
        5) switch_cc_qdisc "cubic" "fq_codel" ;;
        *) log_info "已取消切换。" ;;
    esac
}

menu_forward() {
    printf '\n%s>>> IPv4 / IPv6 内核流量转发 (ip_forward)%s\n' "${C_BOLD}" "${C_RESET}"
    printf '  1) 开启流量转发 (中转机 / NAT / WireGuard 必开)\n'
    printf '  2) 关闭流量转发 (纯单机落地更安全)\n'
    local c
    read -r -p "请选择 [1-2，回车取消]: " c
    case "${c:-}" in
        1) set_ip_forward 1 ;;
        2) set_ip_forward 0 ;;
        *) log_info "已取消操作。" ;;
    esac
}

menu_ip_pref() {
    printf '\n%s>>> 切换出站 IPv4 / IPv6 优先级%s\n' "${C_BOLD}" "${C_RESET}"
    printf '  1) 设为 IPv4 出站优先\n'
    printf '  2) 恢复 IPv6 出站优先 (系统默认)\n'
    local c
    read -r -p "请选择 [1-2，回车取消]: " c
    case "${c:-}" in
        1) set_ip_preference "ipv4" ;;
        2) set_ip_preference "ipv6" ;;
        *) log_info "已取消操作。" ;;
    esac
}

menu_swap() {
    printf '\n%s>>> Swap 虚拟内存与 Swappiness 管理%s\n' "${C_BOLD}" "${C_RESET}"
    local rec_mb=1024
    [ "$MEM_TOTAL_MB" -le 600 ] && rec_mb=1024
    [ "$MEM_TOTAL_MB" -gt 2048 ] && rec_mb=2048

    printf '  1) 创建 / 重建 /swapfile 并调优 swappiness=10\n'
    printf '  2) 移除 /swapfile\n'
    local c
    read -r -p "请选择 [1-2，回车取消]: " c
    case "${c:-}" in
        1)
            local sz
            read -r -p "请输入 Swap 大小 (MiB，默认推荐 ${rec_mb}): " sz
            sz="${sz:-$rec_mb}"
            create_swap_file "$sz"
            ;;
        2)
            remove_swap_file
            ;;
        *)
            log_info "已取消操作。"
            ;;
    esac
}

menu_self_manage() {
    printf '\n%s>>> 脚本更新与卸载管理%s\n' "${C_BOLD}" "${C_RESET}"
    printf '  1) 从 GitHub 在线更新 net-tune 到最新版\n'
    printf '  2) 彻底卸载 net-tune（自动回滚所有内核参数并删除 /usr/local/bin/net-tune）\n'
    local c
    read -r -p "请选择 [1-2，回车取消]: " c
    case "${c:-}" in
        1)
            update_cli_command
            ;;
        2)
            local confirm
            read -r -p "确认回滚所有调优配置并彻底卸载 net-tune 吗？[y/N]: " confirm
            case "${confirm:-N}" in
                [yY]|[yY][eE][sS])
                    uninstall_all
                    exit 0
                    ;;
                *)
                    log_info "已取消卸载。"
                    ;;
            esac
            ;;
        *)
            log_info "已取消操作。"
            ;;
    esac
}

interactive_loop() {
    if [ ! -t 0 ]; then
        if [ -r /dev/tty ]; then
            exec </dev/tty
        else
            log_err "当前处于非交互式终端，无法打开菜单。请附带参数运行（如: --auto 或 --help）。"
            exit 1
        fi
    fi

    # 首次进入面板时自动注册 /usr/local/bin/net-tune 全局快捷命令
    if [ ! -x "$INSTALL_BIN" ]; then
        install_cli_command 0 || true
    else
        install_cli_command 1 || true
    fi

    while true; do
        detect_environment
        show_dashboard 0
        printf ' %s1)%s 一键智能调优 — 均衡通用档 %s(推荐：BBR + FQ + 内存自适应缓冲 + 句柄 + 网卡)%s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
        printf ' %s2)%s 跨国大带宽调优 — BDP 精准计算档 %s(输入带宽与 RTT 精准算参)%s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
        printf ' %s3)%s UDP / QUIC 强化档 %s(适配 Hysteria2 / Tuic / WireGuard 高并发防丢包)%s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
        print_hr
        printf ' %s4)%s 单独切换拥塞控制与队列算法 (BBR / Cubic + FQ / CAKE / FQ_PIE)\n' "${C_CYAN}" "${C_RESET}"
        printf ' %s5)%s 单独执行文件句柄拉满 (ulimit) 与网卡多队列 (RPS/RFS) 优化\n' "${C_CYAN}" "${C_RESET}"
        printf ' %s6)%s 启用并扩容 Conntrack 连接跟踪表 (中转 / 防火墙防满表断流)\n' "${C_CYAN}" "${C_RESET}"
        printf ' %s7)%s 开启 / 关闭 IPv4 & IPv6 流量转发 (ip_forward)\n' "${C_CYAN}" "${C_RESET}"
        printf ' %s8)%s 切换 IPv4 / IPv6 出站优先级 (/etc/gai.conf)\n' "${C_CYAN}" "${C_RESET}"
        printf ' %s9)%s Swap 虚拟内存创建与 Swappiness 优化\n' "${C_CYAN}" "${C_RESET}"
        print_hr
        printf ' %s10)%s 查看详细内核参数体检报告\n' "${C_YELLOW}" "${C_RESET}"
        printf ' %s11)%s 一键回滚默认配置 (保留 net-tune 命令，仅还原系统参数)\n' "${C_RED}" "${C_RESET}"
        printf ' %s12)%s 在线更新脚本 / 彻底卸载 net-tune\n' "${C_BLUE}" "${C_RESET}"
        printf ' %s0)%s  退出面板 %s(下次直接输入 net-tune 即可唤起)%s\n' "${C_BOLD}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
        print_hr

        local choice
        if ! read -r -p "请输入菜单编号 [0-12]: " choice; then
            printf '\n'
            break
        fi

        case "${choice:-}" in
            1)
                run_full_tune "balanced" "fq"
                pause_prompt
                ;;
            2)
                menu_bdp_wizard || true
                pause_prompt
                ;;
            3)
                run_full_tune "udp" ""
                pause_prompt
                ;;
            4)
                menu_switch_qdisc || true
                pause_prompt
                ;;
            5)
                apply_ulimit_tuning
                apply_nic_tuning
                pause_prompt
                ;;
            6)
                tune_conntrack_explicit || true
                pause_prompt
                ;;
            7)
                menu_forward || true
                pause_prompt
                ;;
            8)
                menu_ip_pref || true
                pause_prompt
                ;;
            9)
                menu_swap || true
                pause_prompt
                ;;
            10)
                show_dashboard 1
                pause_prompt
                ;;
            11)
                local confirm
                read -r -p "确认清除所有调优配置并恢复备份吗？[y/N]: " confirm
                case "${confirm:-N}" in
                    [yY]|[yY][eE][sS]) rollback_all ;;
                    *) log_info "已取消回滚。" ;;
                esac
                pause_prompt
                ;;
            12)
                menu_self_manage || true
                pause_prompt
                ;;
            0|q|Q)
                printf '已退出（随时输入 %snet-tune%s 可再次打开面板）。\n' "${C_GREEN}" "${C_RESET}"
                exit 0
                ;;
            *)
                log_warn "无效选项: ${choice}"
                sleep 1
                ;;
        esac
    done
}

# ============================= CLI 参数解析 ===================================
show_help() {
    cat <<EOF
用法: net-tune [选项]

不带参数运行时自动安装全局快捷命令 'net-tune' 并进入交互式菜单面板。

核心模式:
  -a, --auto                     一键智能调优 (等同 --profile balanced，含 BBR+FQ+缓冲+句柄+网卡)
  -p, --profile <模式>           指定调优预设档: balanced | bdp | udp
      --bw <Mbps>                配合 --profile bdp 指定带宽 Mbps (默认: 1000)
      --rtt <ms>                 配合 --profile bdp 指定延迟 ms   (默认: 150)
      --qdisc <算法>             指定队列调度算法: fq | cake | fq_pie | fq_codel

独立功能:
      --conntrack                启用并按内存大小扩容 nf_conntrack 连接跟踪表
      --enable-forward           开启 IPv4 & IPv6 流量转发 (ip_forward=1)
      --disable-forward          关闭 IPv4 & IPv6 流量转发 (ip_forward=0)
      --prefer-ipv4              设置出站连接 IPv4 优先
      --prefer-ipv6              恢复出站连接 IPv6 优先
      --swap <MiB>               一键创建指定 MiB 大小的 /swapfile 并设 swappiness=10
      --remove-swap              卸载并删除 /swapfile

安装、状态与回滚:
  -i, --install                  安装脚本至 /usr/local/bin/net-tune (若无其他动作则随即启动面板)
  -u, --update                   从 GitHub 在线更新 /usr/local/bin/net-tune 到最新版
      --uninstall                一键回滚所有内核参数并删除 net-tune 命令
  -s, --status                   输出当前系统与网络调优详细状态报告 (无需 root)
  -r, --rollback                 一键回滚并清理所有由本脚本写入的调优配置
  -h, --help                     显示本帮助信息

示例:
  net-tune                                      # 启动交互式菜单面板
  net-tune --auto                               # 新机一键全自动均衡调优
  net-tune --profile bdp --bw 2500 --rtt 160    # 2.5Gbps / 160ms 专线精准调优
  net-tune --profile udp --qdisc cake           # UDP 强化档 + CAKE 队列
  net-tune --auto --enable-forward              # 一键调优并同时开启流量中转转发
  net-tune --rollback                           # 一键还原默认状态
EOF
}

main() {
    # 先处理无需 Linux/root 即可查看的 --help
    if [ "$#" -gt 0 ]; then
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
        esac
    fi

    detect_environment
    check_os_compatibility

    if [ "$#" -eq 0 ]; then
        require_root
        interactive_loop
        exit 0
    fi

    local do_install=0
    local do_update=0
    local do_uninstall=0
    local do_status=0
    local do_rollback=0
    local target_profile=""
    local target_qdisc=""
    local bw_mbps="1000"
    local rtt_ms="150"
    local do_conntrack=0
    local forward_action=""
    local ip_pref_action=""
    local swap_mb=""
    local do_remove_swap=0
    local has_other_action=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -i|--install)
                do_install=1
                shift
                ;;
            -u|--update)
                do_update=1
                has_other_action=1
                shift
                ;;
            --uninstall)
                do_uninstall=1
                has_other_action=1
                shift
                ;;
            -s|--status)
                do_status=1
                has_other_action=1
                shift
                ;;
            -r|--rollback)
                do_rollback=1
                has_other_action=1
                shift
                ;;
            -a|--auto)
                target_profile="balanced"
                has_other_action=1
                shift
                ;;
            -p|--profile)
                if [ "$#" -lt 2 ]; then
                    log_err "--profile 需要参数: balanced | bdp | udp"
                    exit 1
                fi
                case "$2" in
                    balanced|bdp|udp) target_profile="$2" ;;
                    *)
                        log_err "未知 profile '$2'，可选值: balanced | bdp | udp"
                        exit 1
                        ;;
                esac
                has_other_action=1
                shift 2
                ;;
            --bw)
                [ "$#" -lt 2 ] && { log_err "--bw 需要正整数参数 (Mbps)"; exit 1; }
                bw_mbps="$2"
                shift 2
                ;;
            --rtt)
                [ "$#" -lt 2 ] && { log_err "--rtt 需要正整数参数 (ms)"; exit 1; }
                rtt_ms="$2"
                shift 2
                ;;
            --qdisc)
                [ "$#" -lt 2 ] && { log_err "--qdisc 需要参数: fq | cake | fq_pie | fq_codel"; exit 1; }
                case "$2" in
                    fq|cake|fq_pie|fq_codel) target_qdisc="$2" ;;
                    *)
                        log_err "不支持的 qdisc '$2'，可选值: fq | cake | fq_pie | fq_codel"
                        exit 1
                        ;;
                esac
                has_other_action=1
                shift 2
                ;;
            --conntrack)
                do_conntrack=1
                has_other_action=1
                shift
                ;;
            --enable-forward)
                forward_action="1"
                has_other_action=1
                shift
                ;;
            --disable-forward)
                forward_action="0"
                has_other_action=1
                shift
                ;;
            --prefer-ipv4)
                ip_pref_action="ipv4"
                has_other_action=1
                shift
                ;;
            --prefer-ipv6)
                ip_pref_action="ipv6"
                has_other_action=1
                shift
                ;;
            --swap)
                [ "$#" -lt 2 ] && { log_err "--swap 需要 MiB 数值参数"; exit 1; }
                swap_mb="$2"
                has_other_action=1
                shift 2
                ;;
            --remove-swap)
                do_remove_swap=1
                has_other_action=1
                shift
                ;;
            *)
                log_err "未知参数: $1 (使用 --help 查看用法)"
                exit 1
                ;;
        esac
    done

    if [ "$do_uninstall" -eq 1 ]; then
        uninstall_all
        exit 0
    fi

    if [ "$do_update" -eq 1 ]; then
        update_cli_command
        exit 0
    fi

    if [ "$do_rollback" -eq 1 ]; then
        rollback_all
        exit 0
    fi

    if [ "$do_install" -eq 1 ]; then
        require_root
        install_cli_command 0
        if [ "$has_other_action" -eq 0 ] && { [ -t 0 ] || [ -r /dev/tty ]; }; then
            interactive_loop
            exit 0
        fi
    fi

    if [ -n "$target_profile" ]; then
        require_root
        [ ! -x "$INSTALL_BIN" ] && install_cli_command 0 || install_cli_command 1 || true
        if ! printf '%s' "$bw_mbps" | grep -qE '^[0-9]+$' || [ "$bw_mbps" -lt 1 ]; then
            log_err "--bw 参数无效: ${bw_mbps}"
            exit 1
        fi
        if ! printf '%s' "$rtt_ms" | grep -qE '^[0-9]+$' || [ "$rtt_ms" -lt 1 ]; then
            log_err "--rtt 参数无效: ${rtt_ms}"
            exit 1
        fi
        run_full_tune "$target_profile" "$target_qdisc" "$bw_mbps" "$rtt_ms"
    elif [ -n "$target_qdisc" ]; then
        local cur_cc
        cur_cc="$(read_sysctl net.ipv4.tcp_congestion_control)"
        [ "$cur_cc" = "N/A" ] && cur_cc="bbr"
        switch_cc_qdisc "$cur_cc" "$target_qdisc"
    fi

    [ "$do_conntrack" -eq 1 ] && tune_conntrack_explicit
    [ -n "$forward_action" ] && set_ip_forward "$forward_action"
    [ -n "$ip_pref_action" ] && set_ip_preference "$ip_pref_action"
    [ "$do_remove_swap" -eq 1 ] && remove_swap_file
    [ -n "$swap_mb" ] && create_swap_file "$swap_mb"

    if [ "$do_status" -eq 1 ]; then
        show_dashboard 1
    fi
}

main "$@"
