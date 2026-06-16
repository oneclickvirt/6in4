#!/usr/bin/env bash
# from
# https://github.com/oneclickvirt/6in4
# 2026.06.05

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }

say_error() {
    _red "$1"
    _red "$2"
}

say_warn() {
    _yellow "$1"
    _yellow "$2"
}

say_ok() {
    _green "$1"
    _green "$2"
}

usage() {
    cat <<'EOF'
Usage:
  ./6in4.sh <client_ipv4> [sit|gre|ipip] [subnet_size] [options]

Options:
  --interface <name>       Force the public server network interface
  --no-telemetry           Disable run counter telemetry
  --skip-health-check      Do not ping the tunnel peer after creation
  --no-persist             Generate persistence files but do not enable services
  --skip-ndpresponder      Skip ndpresponder installation/startup
  --dry-run                Exercise allocation/log/persistence flow without system changes
  -h, --help               Show this help

Environment:
  SIXIN4_STATE_DIR         Default: /var/lib/6in4
  SIXIN4_LOG_DIR           Default: /var/log/6in4
  SIXIN4_NO_TELEMETRY=1    Same as --no-telemetry
  SIXIN4_INTERFACE=<name>  Same as --interface
  SIXIN4_DRY_RUN=1         Same as --dry-run
  6IN4_*                   Accepted through env(1) for compatibility
  CN=true                  Prefer reachable China-friendly GitHub CDNs
EOF
}

read_env() {
    local legacy_name="$1"
    local shell_name="$2"
    local value
    value=$(printenv "$shell_name" 2>/dev/null || true)
    if [ -z "$value" ]; then
        value=$(printenv "$legacy_name" 2>/dev/null || true)
    fi
    printf '%s' "$value"
}

env_state_dir=$(read_env 6IN4_STATE_DIR SIXIN4_STATE_DIR)
env_log_dir=$(read_env 6IN4_LOG_DIR SIXIN4_LOG_DIR)
env_log_max_bytes=$(read_env 6IN4_LOG_MAX_BYTES SIXIN4_LOG_MAX_BYTES)
env_log_keep=$(read_env 6IN4_LOG_KEEP SIXIN4_LOG_KEEP)
env_ttl=$(read_env 6IN4_TTL SIXIN4_TTL)
env_ipv6_route_probe=$(read_env 6IN4_IPV6_ROUTE_PROBE SIXIN4_IPV6_ROUTE_PROBE)
env_interface=$(read_env 6IN4_INTERFACE SIXIN4_INTERFACE)
env_dry_run=$(read_env 6IN4_DRY_RUN SIXIN4_DRY_RUN)
env_os_family=$(read_env 6IN4_OS_FAMILY SIXIN4_OS_FAMILY)
env_distro_id=$(read_env 6IN4_DISTRO_ID SIXIN4_DISTRO_ID)
env_main_ipv4=$(read_env 6IN4_MAIN_IPV4 SIXIN4_MAIN_IPV4)
env_ipv4_cidr=$(read_env 6IN4_IPV4_CIDR SIXIN4_IPV4_CIDR)
env_ipv4_gateway=$(read_env 6IN4_IPV4_GATEWAY SIXIN4_IPV4_GATEWAY)
env_ipv6_cidr=$(read_env 6IN4_IPV6_CIDR SIXIN4_IPV6_CIDR)
env_ipv6_gateway=$(read_env 6IN4_IPV6_GATEWAY SIXIN4_IPV6_GATEWAY)
env_underlay_mtu=$(read_env 6IN4_UNDERLAY_MTU SIXIN4_UNDERLAY_MTU)

STATE_DIR="${env_state_dir:-/var/lib/6in4}"
LOG_DIR="${env_log_dir:-/var/log/6in4}"
PERSIST_DIR="${STATE_DIR}/persistent"
ALLOCATIONS_FILE="${STATE_DIR}/allocations.tsv"
COUNTER_FILE="${STATE_DIR}/tunnel.counter"
LOCK_FILE="${STATE_DIR}/6in4.lock"
SERVER_LOG="${LOG_DIR}/6in4_server.log"
CLIENT_LOG="${LOG_DIR}/6in4_client.log"
LOG_MAX_BYTES="${env_log_max_bytes:-1048576}"
LOG_KEEP="${env_log_keep:-5}"
TUNNEL_TTL="${env_ttl:-255}"
IPV6_ROUTE_PROBE="${env_ipv6_route_probe:-2001:4860:4860::8888}"
NO_TELEMETRY=0
HEALTH_CHECK=1
INSTALL_PERSISTENCE=1
SKIP_NDPRESPONDER=0
DRY_RUN=0
USER_INTERFACE="${env_interface:-}"
cdn_success_url=""
OS_FAMILY=""
DISTRO_ID=""
PKG_MANAGER=""
PACKAGE_UPDATED=0
SYSTEM_ARCH="$(uname -m 2>/dev/null || echo unknown)"
NDP_ARCH=""
NDP_HASH=""
NDP_URL=""
NDP_X86_HASH="64793b094b56f4193148b02684c33ddd80122b3c490814a0dc91673e90df66bc"
NDP_AARCH64_HASH="7b6b5b3248df07d9df9c2919ca10dcf43556876456f55f31e2347d740c5a8683"
LOCK_DIR=""

cleanup_lock() {
    if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

die() {
    say_error "$1" "$2"
    exit 1
}

ensure_root() {
    if [ "$DRY_RUN" -eq 1 ]; then
        say_warn "Dry-run mode: root check skipped." "dry-run 模式：已跳过 root 检查。"
        return 0
    fi
    if [ "$(id -u)" != "0" ]; then
        die "This script must be run as root." "此脚本必须以 root 权限运行。"
    fi
}

prepare_locale() {
    local utf8_locale
    utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8" || true)
    if [ -n "$utf8_locale" ]; then
        export LC_ALL="$utf8_locale"
        export LANG="$utf8_locale"
        export LANGUAGE="$utf8_locale"
    fi
}

prepare_dirs() {
    mkdir -p "$STATE_DIR" "$LOG_DIR" "$PERSIST_DIR" || die "Failed to create state/log directories." "创建状态或日志目录失败。"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    chmod 755 "$LOG_DIR" 2>/dev/null || true
}

refresh_runtime_paths() {
    PERSIST_DIR="${STATE_DIR}/persistent"
    ALLOCATIONS_FILE="${STATE_DIR}/allocations.tsv"
    COUNTER_FILE="${STATE_DIR}/tunnel.counter"
    LOCK_FILE="${STATE_DIR}/6in4.lock"
    SERVER_LOG="${LOG_DIR}/6in4_server.log"
    CLIENT_LOG="${LOG_DIR}/6in4_client.log"
}

apply_runtime_path_defaults() {
    if [ "$DRY_RUN" -eq 1 ]; then
        [ -n "$env_state_dir" ] || STATE_DIR="${TMPDIR:-/tmp}/6in4-dry-run/state"
        [ -n "$env_log_dir" ] || LOG_DIR="${TMPDIR:-/tmp}/6in4-dry-run/log"
        refresh_runtime_paths
    fi
}

is_enabled_value() {
    local value
    value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    [ "$value" = "1" ] || [ "$value" = "true" ] || [ "$value" = "yes" ] || [ "$value" = "on" ]
}

acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            die "Another 6in4 instance is running. Refusing concurrent execution." "检测到另一个 6in4 实例正在运行，已拒绝并发执行。"
        fi
    else
        LOCK_DIR="${STATE_DIR}/.lock"
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            die "Another 6in4 instance is running, or a stale lock exists at ${LOCK_DIR}." "检测到另一个 6in4 实例正在运行，或 ${LOCK_DIR} 存在过期锁。"
        fi
        trap cleanup_lock EXIT INT TERM
    fi
}

migrate_legacy_state() {
    local legacy_dir legacy_file found legacy_used imported subnet
    legacy_dir="${STATE_DIR}/legacy-usr-local-bin"
    found=0
    for legacy_file in /usr/local/bin/6in4_*; do
        [ -e "$legacy_file" ] || continue
        mkdir -p "$legacy_dir"
        cp -n "$legacy_file" "$legacy_dir/" 2>/dev/null || true
        found=1
    done
    if [ "$found" -eq 1 ]; then
        say_warn "Legacy /usr/local/bin/6in4_* state was copied to ${legacy_dir}; new state is kept in ${STATE_DIR}." "已将旧版 /usr/local/bin/6in4_* 状态复制到 ${legacy_dir}；新状态将存储在 ${STATE_DIR}。"
    fi
    legacy_used="/usr/local/bin/6in4_used_subnets"
    [ -f "$legacy_used" ] || return 0
    if [ ! -f "$ALLOCATIONS_FILE" ]; then
        printf 'created_at\tname\tos_family\tmode\tclient_ipv4\tsubnet\tserver_ipv6\tclient_ipv6\tmtu\tmss\tstatus\tdeleted_at\n' >"$ALLOCATIONS_FILE"
    fi
    imported=0
    while IFS= read -r subnet; do
        [ -n "$subnet" ] || continue
        if ! awk -F '\t' -v subnet="$subnet" '$6 == subnet {found=1} END {exit found ? 0 : 1}' "$ALLOCATIONS_FILE"; then
            imported=$((imported + 1))
            printf '%s\tlegacy-%s\tlegacy\tunknown\tunknown\t%s\t\t\t\t\tactive\t\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$imported" "$subnet" >>"$ALLOCATIONS_FILE"
        fi
    done <<EOF
$(awk '/^Network/ {print $3}' "$legacy_used" 2>/dev/null)
EOF
    if [ "$imported" -gt 0 ]; then
        say_warn "Imported ${imported} legacy used subnet record(s) as active placeholders." "已将 ${imported} 条旧版已用子网记录导入为 active 占位记录。"
    fi
}

parse_args() {
    local positional=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --interface)
            [ "$#" -ge 2 ] || die "Missing value for --interface." "--interface 缺少参数值。"
            USER_INTERFACE="$2"
            shift 2
            ;;
        --interface=*)
            USER_INTERFACE="${1#*=}"
            shift
            ;;
        --no-telemetry)
            NO_TELEMETRY=1
            shift
            ;;
        --skip-health-check | --no-health-check)
            HEALTH_CHECK=0
            shift
            ;;
        --no-persist)
            INSTALL_PERSISTENCE=0
            shift
            ;;
        --skip-ndpresponder)
            SKIP_NDPRESPONDER=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            NO_TELEMETRY=1
            HEALTH_CHECK=0
            INSTALL_PERSISTENCE=0
            SKIP_NDPRESPONDER=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do
                positional+=("$1")
                shift
            done
            ;;
        -*)
            die "Unknown option: $1" "未知参数：$1"
            ;;
        *)
            positional+=("$1")
            shift
            ;;
        esac
    done

    target_address="${positional[0]:-}"
    tunnel_mode="${positional[1]:-sit}"
    target_mask="${positional[2]:-80}"

    local env_no_telemetry env_no_telemetry_alias
    env_no_telemetry=$(read_env 6IN4_NO_TELEMETRY SIXIN4_NO_TELEMETRY)
    env_no_telemetry_alias=$(printenv NO_TELEMETRY 2>/dev/null || true)
    if is_enabled_value "${env_dry_run:-}"; then
        DRY_RUN=1
        NO_TELEMETRY=1
        HEALTH_CHECK=0
        INSTALL_PERSISTENCE=0
        SKIP_NDPRESPONDER=1
    fi
    if is_enabled_value "${env_no_telemetry:-}" || is_enabled_value "${env_no_telemetry_alias:-}"; then
        NO_TELEMETRY=1
    fi
}

detect_system() {
    local kernel
    if [ -n "$env_os_family" ]; then
        OS_FAMILY="$env_os_family"
        DISTRO_ID="${env_distro_id:-dry-run}"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        OS_FAMILY="linux"
        DISTRO_ID="${env_distro_id:-dry-run}"
        return 0
    fi
    kernel=$(uname -s 2>/dev/null || echo unknown)
    case "$kernel" in
    Linux)
        OS_FAMILY="linux"
        if [ -r /etc/os-release ]; then
            # shellcheck source=/dev/null
            DISTRO_ID=$(. /etc/os-release && printf '%s' "${ID:-unknown}")
        else
            DISTRO_ID="linux"
        fi
        ;;
    FreeBSD | OpenBSD | NetBSD | DragonFly)
        OS_FAMILY="bsd"
        DISTRO_ID=$(printf '%s' "$kernel" | tr '[:upper:]' '[:lower:]')
        ;;
    *)
        OS_FAMILY="unix"
        DISTRO_ID=$(printf '%s' "$kernel" | tr '[:upper:]' '[:lower:]')
        ;;
    esac
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
    elif command -v pkg >/dev/null 2>&1; then
        PKG_MANAGER="pkg"
    elif command -v pkg_add >/dev/null 2>&1; then
        PKG_MANAGER="pkg_add"
    else
        PKG_MANAGER=""
    fi
}

update_package_index() {
    [ "$PACKAGE_UPDATED" -eq 0 ] || return 0
    case "$PKG_MANAGER" in
    apt)
        local apt_update_output temp_file public_keys joined_keys public_key_args
        temp_file="${STATE_DIR}/apt_fix.txt"
        apt_update_output=$(apt-get update 2>&1)
        printf '%s\n' "$apt_update_output" >"$temp_file"
        if grep -q 'NO_PUBKEY' "$temp_file"; then
            public_keys=$(grep -oE 'NO_PUBKEY [0-9A-F]+' "$temp_file" | awk '{ print $2 }')
            joined_keys=$(printf '%s\n' "$public_keys" | paste -sd " ")
            say_warn "Missing APT public keys: ${joined_keys}; trying to import them." "缺少 APT 公钥：${joined_keys}；正在尝试导入。"
            read -r -a public_key_args <<<"$joined_keys"
            apt-key adv --keyserver keyserver.ubuntu.com --recv-keys "${public_key_args[@]}"
            apt-get update
        fi
        rm -f "$temp_file"
        ;;
    apk)
        apk update
        ;;
    pacman)
        pacman -Sy --noconfirm
        ;;
    dnf)
        dnf -y makecache
        ;;
    yum)
        yum -y makecache
        ;;
    zypper)
        zypper --non-interactive refresh
        ;;
    pkg)
        pkg update -f
        ;;
    pkg_add)
        :
        ;;
    *)
        return 1
        ;;
    esac
    PACKAGE_UPDATED=1
}

install_packages() {
    [ "$#" -gt 0 ] || return 0
    if [ -z "$PKG_MANAGER" ]; then
        return 1
    fi
    update_package_index || true
    case "$PKG_MANAGER" in
    apt) apt-get -y install "$@" ;;
    apk) apk add --no-cache "$@" ;;
    pacman) pacman -S --noconfirm --needed "$@" ;;
    dnf) dnf -y install "$@" ;;
    yum) yum -y install "$@" ;;
    zypper) zypper --non-interactive install -y "$@" ;;
    pkg) pkg install -y "$@" ;;
    pkg_add) pkg_add -I "$@" ;;
    *) return 1 ;;
    esac
}

package_for_command() {
    local command_name="$1"
    case "$command_name" in
    ip)
        case "$PKG_MANAGER" in
        yum | dnf) printf '%s' "iproute" ;;
        *) printf '%s' "iproute2" ;;
        esac
        ;;
    python3)
        printf '%s' "python3"
        ;;
    curl)
        printf '%s' "curl"
        ;;
    ping)
        case "$PKG_MANAGER" in
        apt) printf '%s' "iputils-ping" ;;
        apk) printf '%s' "iputils" ;;
        pacman) printf '%s' "iputils" ;;
        yum | dnf) printf '%s' "iputils" ;;
        *) printf '%s' "iputils" ;;
        esac
        ;;
    ip6tables)
        case "$PKG_MANAGER" in
        apk) printf '%s' "iptables" ;;
        *) printf '%s' "iptables" ;;
        esac
        ;;
    *)
        printf '%s' "$command_name"
        ;;
    esac
}

ensure_command() {
    local command_name="$1"
    local package_name
    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi
    package_name=$(package_for_command "$command_name")
    say_warn "Installing missing dependency: ${package_name}" "正在安装缺失依赖：${package_name}"
    install_packages "$package_name" || die "Missing required command '${command_name}', and automatic installation failed." "缺少必要命令 ${command_name}，且自动安装失败。"
    command -v "$command_name" >/dev/null 2>&1 || die "Command '${command_name}' is still unavailable after installation." "安装后仍无法找到命令 ${command_name}。"
}

ensure_dependencies() {
    if [ "$DRY_RUN" -eq 1 ]; then
        ensure_command python3
        return 0
    fi
    ensure_command curl
    ensure_command python3
    if [ "$OS_FAMILY" = "linux" ]; then
        ensure_command ip
        ensure_command ping
    fi
}

is_ipv4() {
    local ip="$1"
    local a b c d extra octet
    IFS=. read -r a b c d extra <<<"$ip"
    [ -z "${extra:-}" ] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        [ "$octet" = "${octet#0}" ] || [ "$octet" = "0" ] || return 1
        [ "$octet" -ge 0 ] 2>/dev/null || return 1
        [ "$octet" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

is_private_ipv6() {
    local address="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$address" <<'PY'
import ipaddress
import sys

raw = sys.argv[1].split("%", 1)[0]
try:
    ip = ipaddress.ip_address(raw)
except ValueError:
    sys.exit(0)
if ip.version != 6:
    sys.exit(0)
sys.exit(1 if ip.is_global else 0)
PY
        return $?
    fi

    local lower
    lower=$(printf '%s' "$address" | tr '[:upper:]' '[:lower:]')
    [ -n "$lower" ] || return 0
    [[ "$lower" == *:* ]] || return 0
    case "$lower" in
    fe80:* | fc*:* | fd*:* | 2001:db8:* | ::1 | ::ffff:* | 2002:* | ff*) return 0 ;;
    esac
    return 1
}

validate_inputs() {
    [ -n "$target_address" ] || die "Client IPv4 address is required." "必须设置客户端 IPv4 地址。"
    if is_ipv4 "$target_address"; then
        say_ok "Client IPv4 address: ${target_address}" "客户端 IPv4 地址：${target_address}"
    else
        die "Invalid client IPv4 address: ${target_address}" "客户端 IPv4 地址不合法：${target_address}"
    fi

    case "$tunnel_mode" in
    sit | gre | ipip) ;;
    *)
        die "Unsupported tunnel mode: ${tunnel_mode}. Use sit, gre, or ipip." "不支持的隧道模式：${tunnel_mode}。请使用 sit、gre 或 ipip。"
        ;;
    esac

    [[ "$target_mask" =~ ^[0-9]+$ ]] || die "Subnet size must be an integer." "子网长度必须是整数。"
    [ "$target_mask" -ge 1 ] && [ "$target_mask" -le 128 ] || die "Subnet size must be between 1 and 128." "子网长度必须在 1 到 128 之间。"
    if [ $((target_mask % 8)) -ne 0 ]; then
        die "Subnet size must be a multiple of 8 for stable allocation records." "子网长度必须是 8 的倍数，以保证分配记录稳定。"
    fi

    if [ "$OS_FAMILY" = "bsd" ] && [ "$tunnel_mode" != "sit" ]; then
        die "BSD systems use gif(4) for IPv6-over-IPv4 here; only sit mode is supported." "BSD 系统在此使用 gif(4) 实现 IPv6-over-IPv4，仅支持 sit 模式。"
    fi
}

statistics_of_run_times() {
    if [ "$DRY_RUN" -eq 1 ]; then
        say_warn "Dry-run mode: telemetry skipped." "dry-run 模式：已跳过统计上报。"
        return 0
    fi
    [ "$NO_TELEMETRY" -eq 0 ] || {
        say_warn "Telemetry disabled by option or environment." "已通过参数或环境变量关闭统计上报。"
        return 0
    }

    local count today total
    count=$(curl -4 -ksm1 "https://hits.spiritlhl.net/6in4?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null ||
        curl -6 -ksm1 "https://hits.spiritlhl.net/6in4?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null || true)
    today=$(printf '%s\n' "$count" | sed -n 's/.*"daily"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    total=$(printf '%s\n' "$count" | sed -n 's/.*"total"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    [ -n "$today" ] || today="unknown"
    [ -n "$total" ] || total="unknown"
    _green "Script runs today: ${today}, total runs: ${total}"
    _green "脚本当天运行次数：${today}，累计运行次数：${total}"
}

detect_china() {
    local cn_env response
    if [ "$DRY_RUN" -eq 1 ]; then
        CN=false
        return 0
    fi
    cn_env=$(printf '%s' "${CN:-}" | tr '[:upper:]' '[:lower:]')
    if [ "$cn_env" = "true" ] || [ "$cn_env" = "1" ] || [ "$cn_env" = "yes" ]; then
        CN=true
        return 0
    fi

    say_warn "Detecting network region for CDN selection..." "正在检测网络区域以选择 CDN..."
    response=$(curl -m 6 -s https://ipapi.co/json 2>/dev/null || true)
    if printf '%s' "$response" | grep -Eiq '"country"[[:space:]]*:[[:space:]]*"CN"|China'; then
        CN=true
        say_warn "China network detected; reachable GitHub CDN will be selected automatically." "检测到中国网络，将自动选择可用的 GitHub CDN。"
        return 0
    fi

    response=$(curl -m 6 -s cip.cc 2>/dev/null || true)
    if printf '%s' "$response" | grep -q "中国"; then
        CN=true
        say_warn "China network detected; reachable GitHub CDN will be selected automatically." "检测到中国网络，将自动选择可用的 GitHub CDN。"
    else
        CN=false
    fi
}

select_cdn() {
    local test_url cdn_url
    if [ "$DRY_RUN" -eq 1 ]; then
        cdn_success_url=""
        return 0
    fi
    test_url="https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    cdn_success_url=""
    local cdn_urls=(
        "https://cdn0.spiritlhl.top/"
        "http://cdn3.spiritlhl.net/"
        "http://cdn1.spiritlhl.net/"
        "http://cdn2.spiritlhl.net/"
        "https://ghproxy.com/"
    )

    if [ "${CN:-false}" != "true" ]; then
        say_warn "Direct GitHub access will be used unless it fails." "将优先使用 GitHub 直连，失败时再使用 CDN。"
        return 0
    fi

    for cdn_url in "${cdn_urls[@]}"; do
        if curl -fsSL -k --max-time 6 "${cdn_url}${test_url}" 2>/dev/null | grep -q "success"; then
            cdn_success_url="$cdn_url"
            say_ok "CDN available: ${cdn_success_url}" "可用 CDN：${cdn_success_url}"
            return 0
        fi
    done
    say_warn "No CDN passed the check; direct GitHub URLs will be used." "没有 CDN 通过检测，将使用 GitHub 直连地址。"
}

detect_arch() {
    local arch
    arch=$(printf '%s' "$SYSTEM_ARCH" | tr '[:upper:]' '[:lower:]')
    case "$arch" in
    x86_64 | amd64 | i386 | i686)
        NDP_ARCH="x86"
        NDP_HASH="$NDP_X86_HASH"
        NDP_URL="https://github.com/oneclickvirt/pve/releases/download/ndpresponder_x86/ndpresponder"
        ;;
    aarch64 | arm64)
        NDP_ARCH="aarch64"
        NDP_HASH="$NDP_AARCH64_HASH"
        NDP_URL="https://github.com/oneclickvirt/pve/releases/download/ndpresponder_aarch64/ndpresponder"
        ;;
    riscv64 | riscv*)
        NDP_ARCH="unsupported-riscv"
        ;;
    mips* | loongarch* | ppc* | s390x | armv6* | armv7*)
        NDP_ARCH="unsupported-${arch}"
        ;;
    *)
        NDP_ARCH="unsupported-${arch}"
        ;;
    esac
}

hash_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        return 1
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    local real_url="${cdn_success_url}${url}"
    curl -fL --connect-timeout 10 --retry 2 --retry-delay 1 "$real_url" -o "$output"
}

rotate_log() {
    local log_file="$1"
    local i prev
    [ -f "$log_file" ] || return 0
    local size
    size=$(wc -c <"$log_file" 2>/dev/null || echo 0)
    [ "$size" -lt "$LOG_MAX_BYTES" ] && return 0
    i="$LOG_KEEP"
    while [ "$i" -ge 1 ]; do
        prev=$((i - 1))
        if [ "$prev" -eq 0 ]; then
            [ -f "$log_file" ] && mv -f "$log_file" "${log_file}.1"
        elif [ -f "${log_file}.${prev}" ]; then
            mv -f "${log_file}.${prev}" "${log_file}.${i}"
        fi
        i=$((i - 1))
    done
}

append_log_block() {
    local log_file="$1"
    shift
    rotate_log "$log_file"
    {
        printf '# created_at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '%s\n' "$@"
        printf '%s\n' "-----------------------------------------------------------------------------------------------"
    } >>"$log_file"
}

run_or_die() {
    local description="$1"
    shift
    _blue "$*"
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    if "$@"; then
        return 0
    fi
    die "Command failed while ${description}: $*" "执行失败（${description}）：$*"
}

warn_command() {
    local description="$1"
    shift
    _blue "$*"
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    if ! "$@"; then
        say_warn "Command failed while ${description}: $*" "执行失败（${description}）：$*"
        return 1
    fi
    return 0
}

is_excluded_interface() {
    case "$1" in
    lo | lo0 | docker* | br-* | virbr* | veth* | tun* | tap* | wg* | tailscale* | zerotier* | ipsec* | sit* | gre* | ipip* | gif* | ppp* | dummy* | bond*.* | vlan*)
        return 0
        ;;
    esac
    return 1
}

linux_interface_has_global_ipv4() {
    ip -o -4 addr show dev "$1" scope global 2>/dev/null | grep -q ' inet '
}

detect_linux_interface() {
    local iface route_line candidate
    if [ -n "$USER_INTERFACE" ]; then
        ip link show dev "$USER_INTERFACE" >/dev/null 2>&1 || die "Interface not found: ${USER_INTERFACE}" "找不到指定网卡：${USER_INTERFACE}"
        printf '%s\n' "$USER_INTERFACE"
        return 0
    fi

    route_line=$(ip -4 route get "$target_address" 2>/dev/null | head -n 1 || true)
    iface=$(printf '%s\n' "$route_line" | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    if [ -n "$iface" ] && ! is_excluded_interface "$iface" && linux_interface_has_global_ipv4 "$iface"; then
        printf '%s\n' "$iface"
        return 0
    fi

    iface=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    if [ -n "$iface" ] && ! is_excluded_interface "$iface" && linux_interface_has_global_ipv4 "$iface"; then
        printf '%s\n' "$iface"
        return 0
    fi

    while read -r candidate; do
        [ -n "$candidate" ] || continue
        is_excluded_interface "$candidate" && continue
        linux_interface_has_global_ipv4 "$candidate" || continue
        printf '%s\n' "$candidate"
        return 0
    done <<EOF
$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}' | cut -d@ -f1 | sort -u)
EOF

    die "No non-virtual public IPv4 interface was found." "未找到非虚拟且带公网 IPv4 的网卡。"
}

detect_bsd_interface() {
    local iface
    if [ -n "$USER_INTERFACE" ]; then
        ifconfig "$USER_INTERFACE" >/dev/null 2>&1 || die "Interface not found: ${USER_INTERFACE}" "找不到指定网卡：${USER_INTERFACE}"
        printf '%s\n' "$USER_INTERFACE"
        return 0
    fi
    iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')
    if [ -n "$iface" ] && ! is_excluded_interface "$iface"; then
        printf '%s\n' "$iface"
        return 0
    fi
    iface=$(ifconfig -l 2>/dev/null | tr ' ' '\n' | while read -r candidate; do
        is_excluded_interface "$candidate" && continue
        if ifconfig "$candidate" 2>/dev/null | grep -q 'inet '; then
            printf '%s\n' "$candidate"
            break
        fi
    done)
    [ -n "$iface" ] || die "No non-virtual IPv4 interface was found." "未找到非虚拟 IPv4 网卡。"
    printf '%s\n' "$iface"
}

detect_interface() {
    if [ "$OS_FAMILY" = "linux" ]; then
        detect_linux_interface
    elif [ "$OS_FAMILY" = "bsd" ]; then
        detect_bsd_interface
    else
        die "Unsupported Unix platform: ${DISTRO_ID}. Linux and BSD are supported." "不支持的类 Unix 平台：${DISTRO_ID}。当前支持 Linux 和 BSD。"
    fi
}

get_linux_ipv4_cidr() {
    ip -o -4 addr show dev "$interface" scope global 2>/dev/null | awk '{print $4; exit}'
}

get_linux_main_ipv4() {
    local src
    src=$(ip -4 route get "$target_address" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    if [ -z "$src" ]; then
        src=$(get_linux_ipv4_cidr | cut -d/ -f1)
    fi
    printf '%s\n' "$src"
}

get_linux_ipv4_gateway() {
    ip -4 route show default dev "$interface" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}'
}

get_linux_ipv6_cidr() {
    ip -o -6 addr show dev "$interface" scope global 2>/dev/null | awk '!/ deprecated / {print $4; exit}'
}

get_linux_ipv6_gateway() {
    local route_line gateway
    route_line=$(ip -6 route get "$IPV6_ROUTE_PROBE" from "$ipv6_address" oif "$interface" 2>/dev/null | head -n 1 || true)
    gateway=$(printf '%s\n' "$route_line" | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
    if [ -z "$gateway" ]; then
        gateway=$(ip -6 route show default dev "$interface" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}' | head -n 1)
    fi
    printf '%s\n' "$gateway"
}

get_bsd_ipv4_cidr() {
    local addr
    addr=$(ifconfig "$interface" 2>/dev/null | awk '$1=="inet" {print $2; exit}')
    [ -n "$addr" ] && printf '%s/32\n' "$addr"
}

get_bsd_main_ipv4() {
    get_bsd_ipv4_cidr | cut -d/ -f1
}

get_bsd_ipv4_gateway() {
    route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}'
}

get_bsd_ipv6_cidr() {
    ifconfig "$interface" 2>/dev/null | awk '
        $1=="inet6" && $2 !~ /^fe80/ {
            prefix="64"
            for (i=1;i<=NF;i++) {
                if ($i=="prefixlen") {
                    prefix=$(i+1)
                }
            }
            print $2 "/" prefix
            exit
        }'
}

get_bsd_ipv6_gateway() {
    route -n get -inet6 default 2>/dev/null | awk '/gateway:/ {print $2; exit}'
}

collect_network_info() {
    if [ "$DRY_RUN" -eq 1 ]; then
        interface="${USER_INTERFACE:-dry0}"
        ipv4_address="${env_ipv4_cidr:-198.51.100.2/24}"
        main_ipv4="${env_main_ipv4:-${ipv4_address%/*}}"
        ipv4_gateway="${env_ipv4_gateway:-198.51.100.1}"
        ipv6_cidr="${env_ipv6_cidr:-2001:470:64::1/64}"
        ipv6_gateway="${env_ipv6_gateway:-fe80::1}"
        ipv6_address="${ipv6_cidr%/*}"
        ipv6_prefixlen="${ipv6_cidr#*/}"
        ipv6_network=$(python3 - "$ipv6_address/$ipv6_prefixlen" <<'PY'
import ipaddress
import sys

print(ipaddress.IPv6Interface(sys.argv[1]).network.with_prefixlen)
PY
)
        ipv4_prefixlen="${ipv4_address#*/}"
        if is_private_ipv6 "$ipv6_address"; then
            die "The dry-run IPv6 address is not globally routable: ${ipv6_address}" "dry-run IPv6 地址不是公网可路由地址：${ipv6_address}"
        fi
        _blue "dry_run: true"
        _blue "ipv6_address: ${ipv6_address}"
        _blue "ipv6_prefixlen: ${ipv6_prefixlen}"
        _blue "ipv6_gateway: ${ipv6_gateway:-none}"
        _blue "ipv6_network: ${ipv6_network}"
        _blue "interface: ${interface}"
        _blue "main_ipv4: ${main_ipv4}"
        _blue "ipv4_address: ${ipv4_address}"
        _blue "ipv4_prefixlen: ${ipv4_prefixlen}"
        _blue "ipv4_gateway: ${ipv4_gateway:-none}"
        return 0
    fi

    interface=$(detect_interface)
    if [ "$OS_FAMILY" = "linux" ]; then
        ipv4_address=$(get_linux_ipv4_cidr)
        main_ipv4=$(get_linux_main_ipv4)
        ipv4_gateway=$(get_linux_ipv4_gateway)
        ipv6_cidr=$(get_linux_ipv6_cidr)
    else
        ipv4_address=$(get_bsd_ipv4_cidr)
        main_ipv4=$(get_bsd_main_ipv4)
        ipv4_gateway=$(get_bsd_ipv4_gateway)
        ipv6_cidr=$(get_bsd_ipv6_cidr)
    fi

    [ -n "$ipv4_address" ] || die "No global IPv4 CIDR found on ${interface}." "网卡 ${interface} 上没有找到全局 IPv4 CIDR。"
    [ -n "$main_ipv4" ] || die "No source IPv4 address found on ${interface}." "网卡 ${interface} 上没有找到源 IPv4 地址。"
    [ -n "$ipv6_cidr" ] || die "No global IPv6 CIDR found on ${interface}." "网卡 ${interface} 上没有找到全局 IPv6 CIDR。"

    ipv6_address="${ipv6_cidr%/*}"
    ipv6_prefixlen="${ipv6_cidr#*/}"
    ipv6_network=$(python3 - "$ipv6_address/$ipv6_prefixlen" <<'PY'
import ipaddress
import sys

print(ipaddress.IPv6Interface(sys.argv[1]).network.with_prefixlen)
PY
)
    ipv4_prefixlen="${ipv4_address#*/}"
    if is_private_ipv6 "$ipv6_address"; then
        die "The selected IPv6 address is not globally routable: ${ipv6_address}" "选择的 IPv6 地址不是公网可路由地址：${ipv6_address}"
    fi

    if [ "$OS_FAMILY" = "linux" ]; then
        ipv6_gateway=$(get_linux_ipv6_gateway)
    else
        ipv6_gateway=$(get_bsd_ipv6_gateway)
    fi

    _blue "ipv6_address: ${ipv6_address}"
    _blue "ipv6_prefixlen: ${ipv6_prefixlen}"
    _blue "ipv6_gateway: ${ipv6_gateway:-none}"
    _blue "ipv6_network: ${ipv6_network}"
    _blue "interface: ${interface}"
    _blue "main_ipv4: ${main_ipv4}"
    _blue "ipv4_address: ${ipv4_address}"
    _blue "ipv4_prefixlen: ${ipv4_prefixlen}"
    _blue "ipv4_gateway: ${ipv4_gateway:-none}"
}

calculate_target_prefix() {
    local total_prefix="$1"
    local requested_prefix="$2"
    local diff adjusted
    [[ "$total_prefix" =~ ^[0-9]+$ ]] || die "Invalid detected IPv6 prefix length: ${total_prefix}" "检测到的 IPv6 前缀长度无效：${total_prefix}"
    [ "$requested_prefix" -ge "$total_prefix" ] || die "Subnet size /${requested_prefix} is smaller than server prefix /${total_prefix}." "子网长度 /${requested_prefix} 小于服务端前缀 /${total_prefix}。"
    diff=$((requested_prefix - total_prefix))
    if [ "$diff" -gt 16 ]; then
        adjusted=$((total_prefix + 8 - (total_prefix % 8)))
        [ "$adjusted" -le 128 ] || die "Cannot adjust subnet size safely from /${total_prefix}." "无法从 /${total_prefix} 安全调整子网长度。"
        say_warn "Subnet size adjusted from /${requested_prefix} to /${adjusted} to keep allocation bounded." "为避免分配数量过大，子网长度已从 /${requested_prefix} 调整为 /${adjusted}。"
        printf '%s\n' "$adjusted"
    else
        printf '%s\n' "$requested_prefix"
    fi
}

safe_pool_name() {
    printf '%s_%s_%s' "$ipv6_address" "$ipv6_prefixlen" "$target_mask" | tr '/:.' '____'
}

generate_subnet_pool() {
    local pool_file tmp_file
    pool_file="${STATE_DIR}/subnets_$(safe_pool_name).list"
    if [ -s "$pool_file" ]; then
        printf '%s\n' "$pool_file"
        return 0
    fi

    tmp_file="${pool_file}.tmp"
    python3 - "$ipv6_address/$ipv6_prefixlen" "$target_mask" >"$tmp_file" <<'PY'
import ipaddress
import sys

interface = ipaddress.IPv6Interface(sys.argv[1])
target = int(sys.argv[2])
if target < interface.network.prefixlen:
    raise SystemExit("target prefix is smaller than source prefix")
for subnet in interface.network.subnets(new_prefix=target):
    if interface.ip in subnet:
        continue
    print(subnet.with_prefixlen)
PY
    [ -s "$tmp_file" ] || die "No allocatable IPv6 subnet was generated." "没有生成可分配的 IPv6 子网。"
    mv -f "$tmp_file" "$pool_file"
    printf '%s\n' "$pool_file"
}

active_subnet_exists() {
    local subnet="$1"
    [ -f "$ALLOCATIONS_FILE" ] || return 1
    awk -F '\t' -v subnet="$subnet" '$6 == subnet && $11 == "active" {found=1} END {exit found ? 0 : 1}' "$ALLOCATIONS_FILE"
}

allocate_subnet() {
    local pool_file subnet
    pool_file=$(generate_subnet_pool)
    while IFS= read -r subnet; do
        [ -n "$subnet" ] || continue
        if ! active_subnet_exists "$subnet"; then
            printf '%s\n' "$subnet"
            return 0
        fi
    done <"$pool_file"
    die "No free IPv6 subnet remains for /${target_mask}." "没有剩余可用的 /${target_mask} IPv6 子网。"
}

next_tunnel_name() {
    local id name
    id=0
    [ -f "$COUNTER_FILE" ] && id=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    while :; do
        id=$((id + 1))
        if [ "$OS_FAMILY" = "bsd" ]; then
            name="gif${id}"
        else
            name="server-ipv6-${id}"
        fi
        if ! tunnel_exists "$name"; then
            printf '%s\n' "$id" >"$COUNTER_FILE"
            printf '%s\n' "$name"
            return 0
        fi
    done
}

tunnel_exists() {
    local name="$1"
    [ "$DRY_RUN" -eq 0 ] || return 1
    if [ "$OS_FAMILY" = "linux" ]; then
        ip link show dev "$name" >/dev/null 2>&1
    else
        ifconfig "$name" >/dev/null 2>&1
    fi
}

derive_subnet_addresses() {
    local subnet="$1"
    python3 - "$subnet" <<'PY'
import ipaddress
import sys

net = ipaddress.IPv6Network(sys.argv[1], strict=False)
server = net.network_address + 1
client = net.network_address + 2
print(server)
print(client)
PY
}

calculate_mtu() {
    local underlay_mtu overhead
    underlay_mtu=""
    if [ "$DRY_RUN" -eq 1 ]; then
        underlay_mtu="${env_underlay_mtu:-1500}"
    elif [ "$OS_FAMILY" = "linux" ] && [ -r "/sys/class/net/${interface}/mtu" ]; then
        underlay_mtu=$(cat "/sys/class/net/${interface}/mtu")
    elif [ "$OS_FAMILY" = "linux" ]; then
        underlay_mtu=$(ip -o link show dev "$interface" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="mtu") {print $(i+1); exit}}')
    elif [ "$OS_FAMILY" = "bsd" ]; then
        underlay_mtu=$(ifconfig "$interface" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="mtu") {print $(i+1); exit}}' | head -n 1)
    fi
    [[ "$underlay_mtu" =~ ^[0-9]+$ ]] || underlay_mtu=1500
    case "$tunnel_mode" in
    gre) overhead=24 ;;
    *) overhead=20 ;;
    esac
    tunnel_mtu=$((underlay_mtu - overhead))
    if [ "$tunnel_mtu" -lt 1280 ]; then
        say_warn "Calculated tunnel MTU ${tunnel_mtu} is below IPv6 minimum; using 1280." "计算出的隧道 MTU ${tunnel_mtu} 低于 IPv6 最小值，改用 1280。"
        tunnel_mtu=1280
    fi
    tcp_mss=$((tunnel_mtu - 60))
    [ "$tcp_mss" -ge 1220 ] || tcp_mss=1220
    _blue "underlay_mtu: ${underlay_mtu}"
    _blue "tunnel_mtu: ${tunnel_mtu}"
    _blue "tcp_mss: ${tcp_mss}"
}

ensure_kernel_module() {
    [ "$DRY_RUN" -eq 0 ] || return 0
    [ "$OS_FAMILY" = "linux" ] || return 0
    local module="$1"
    if [ "$module" = "sit" ]; then
        module="sit"
    elif [ "$module" = "gre" ]; then
        module="ip_gre"
    elif [ "$module" = "ipip" ]; then
        module="ipip"
    fi

    if [ -r /proc/modules ] && grep -q "^${module}[[:space:]]" /proc/modules; then
        return 0
    fi
    if command -v modprobe >/dev/null 2>&1; then
        if modprobe "$module" 2>/dev/null; then
            return 0
        fi
        if [ "$module" = "sit" ]; then
            say_warn "Could not load '${module}' with modprobe; it may be built into the kernel. Tunnel creation will verify it." "无法通过 modprobe 加载 ${module}；它可能已内建到内核中，后续隧道创建会验证。"
            return 0
        fi
    fi
    die "Kernel module '${module}' is unavailable. Try: modprobe ${module}" "内核模块 ${module} 不可用。可尝试执行：modprobe ${module}"
}

update_sysctl() {
    [ "$OS_FAMILY" = "linux" ] || return 0
    local setting="$1"
    local key="${setting%%=*}"
    local value="${setting#*=}"
    local escaped_key
    # shellcheck disable=SC2016
    escaped_key=$(printf '%s' "$key" | sed 's/[.[\*^$()+?{}|]/\\&/g')
    if [ -f /etc/sysctl.conf ]; then
        if grep -Eq "^[#[:space:]]*${escaped_key}[[:space:]]*=" /etc/sysctl.conf; then
            sed -i.bak -E "s|^[#[:space:]]*${escaped_key}[[:space:]]*=.*|${key}=${value}|" /etc/sysctl.conf
        else
            printf '%s\n' "$setting" >>/etc/sysctl.conf
        fi
    fi
    sysctl -w "$setting" >/dev/null 2>&1 || say_warn "Failed to apply sysctl ${setting} at runtime." "运行时应用 sysctl ${setting} 失败。"
}

configure_mss_clamp() {
    [ "$OS_FAMILY" = "linux" ] || return 0
    if ! command -v ip6tables >/dev/null 2>&1; then
        say_warn "ip6tables is unavailable; TCP MSS clamping was not installed." "未找到 ip6tables，未安装 TCP MSS Clamping 规则。"
        return 0
    fi
    local direction
    for direction in -o -i; do
        if ip6tables -t mangle -C FORWARD "$direction" "$tunnel_name" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$tcp_mss" 2>/dev/null; then
            continue
        fi
        warn_command "adding TCP MSS clamp" ip6tables -t mangle -A FORWARD "$direction" "$tunnel_name" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$tcp_mss" || true
    done
}

configure_linux_tunnel() {
    ensure_kernel_module "$tunnel_mode"
    if [ "$DRY_RUN" -eq 1 ]; then
        run_or_die "creating tunnel" ip tunnel add "$tunnel_name" mode "$tunnel_mode" remote "$target_address" local "$main_ipv4" ttl "$TUNNEL_TTL"
        run_or_die "setting tunnel MTU" ip link set "$tunnel_name" mtu "$tunnel_mtu"
        run_or_die "bringing tunnel up" ip link set "$tunnel_name" up
        run_or_die "adding server IPv6 address" ip addr add "${server_ipv6}/${target_mask}" dev "$tunnel_name"
        run_or_die "installing IPv6 subnet route" ip route replace "$allocated_subnet" dev "$tunnel_name"
        return 0
    fi
    run_or_die "creating tunnel" ip tunnel add "$tunnel_name" mode "$tunnel_mode" remote "$target_address" local "$main_ipv4" ttl "$TUNNEL_TTL"
    if ! ip link set "$tunnel_name" mtu "$tunnel_mtu"; then
        ip tunnel del "$tunnel_name" 2>/dev/null || true
        die "Failed to set tunnel MTU." "设置隧道 MTU 失败。"
    fi
    if ! ip link set "$tunnel_name" up; then
        ip tunnel del "$tunnel_name" 2>/dev/null || true
        die "Failed to bring tunnel up." "启用隧道失败。"
    fi
    if ! ip addr add "${server_ipv6}/${target_mask}" dev "$tunnel_name"; then
        ip tunnel del "$tunnel_name" 2>/dev/null || true
        die "Failed to add server IPv6 address." "添加服务端 IPv6 地址失败。"
    fi
    if ! ip route replace "$allocated_subnet" dev "$tunnel_name"; then
        ip tunnel del "$tunnel_name" 2>/dev/null || true
        die "Failed to install IPv6 subnet route." "安装 IPv6 子网路由失败。"
    fi

    update_sysctl "net.ipv6.conf.all.forwarding=1"
    update_sysctl "net.ipv6.conf.all.proxy_ndp=1"
    update_sysctl "net.ipv6.conf.default.proxy_ndp=1"
    update_sysctl "net.ipv6.conf.${interface}.proxy_ndp=1"
    update_sysctl "net.ipv6.conf.${tunnel_name}.proxy_ndp=1"
    update_sysctl "net.ipv6.conf.all.accept_ra=2"
    configure_mss_clamp
}

configure_bsd_tunnel() {
    if [ "$DRY_RUN" -eq 1 ]; then
        run_or_die "creating gif tunnel" ifconfig "$tunnel_name" create
        run_or_die "configuring gif tunnel endpoints" ifconfig "$tunnel_name" tunnel "$main_ipv4" "$target_address"
        run_or_die "adding IPv6 addresses to gif tunnel" ifconfig "$tunnel_name" inet6 "$server_ipv6" "$client_ipv6" prefixlen "$target_mask"
        warn_command "setting gif MTU" ifconfig "$tunnel_name" mtu "$tunnel_mtu" || true
        warn_command "adding IPv6 route" route -n add -inet6 "$allocated_subnet" -interface "$tunnel_name" || true
        return 0
    fi
    run_or_die "creating gif tunnel" ifconfig "$tunnel_name" create
    if ! ifconfig "$tunnel_name" tunnel "$main_ipv4" "$target_address"; then
        ifconfig "$tunnel_name" destroy 2>/dev/null || true
        die "Failed to configure gif tunnel endpoints." "配置 gif 隧道端点失败。"
    fi
    if ! ifconfig "$tunnel_name" inet6 "$server_ipv6" "$client_ipv6" prefixlen "$target_mask"; then
        ifconfig "$tunnel_name" destroy 2>/dev/null || true
        die "Failed to add IPv6 addresses to gif tunnel." "为 gif 隧道添加 IPv6 地址失败。"
    fi
    warn_command "setting gif MTU" ifconfig "$tunnel_name" mtu "$tunnel_mtu" || true
    warn_command "adding IPv6 route" route -n add -inet6 "$allocated_subnet" -interface "$tunnel_name" || true
    warn_command "enabling IPv6 forwarding" sysctl net.inet6.ip6.forwarding=1 || true
}

verify_ndpresponder_hash() {
    local file="$1"
    local actual
    actual=$(hash_file "$file") || return 1
    [ "$actual" = "$NDP_HASH" ]
}

write_ndpresponder_systemd() {
    cat >/etc/systemd/system/ndpresponder.service <<EOF
[Unit]
Description=IPv6 NDP responder for 6in4
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ndpresponder -i ${interface} -n ${ipv6_network}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/ndpresponder.service
    systemctl daemon-reload
    systemctl enable --now ndpresponder
}

write_ndpresponder_openrc() {
    cat >/etc/init.d/ndpresponder <<EOF
#!/sbin/openrc-run
name="ndpresponder"
description="IPv6 NDP responder for 6in4"
command="/usr/local/bin/ndpresponder"
command_args="-i ${interface} -n ${ipv6_network}"
command_background="yes"
pidfile="/run/ndpresponder.pid"
depend() {
    need net
}
EOF
    chmod 755 /etc/init.d/ndpresponder
    rc-update add ndpresponder default
    rc-service ndpresponder restart
}

install_ndpresponder() {
    if [ "$DRY_RUN" -eq 1 ]; then
        say_warn "Dry-run mode: ndpresponder installation skipped." "dry-run 模式：已跳过 ndpresponder 安装。"
        return 0
    fi
    [ "$SKIP_NDPRESPONDER" -eq 0 ] || {
        say_warn "ndpresponder skipped by option." "已通过参数跳过 ndpresponder。"
        return 0
    }
    [ "$OS_FAMILY" = "linux" ] || {
        say_warn "ndpresponder auto-install is Linux-only; BSD route/NDP setup must be handled by the platform." "ndpresponder 自动安装仅支持 Linux；BSD 需使用平台自身路由/NDP 配置。"
        return 0
    }
    if [[ "$NDP_ARCH" == unsupported-* ]]; then
        die "No verified ndpresponder binary is available for architecture ${SYSTEM_ARCH}. Build it manually or rerun with --skip-ndpresponder." "架构 ${SYSTEM_ARCH} 没有已校验的 ndpresponder 预编译二进制。请手动构建，或使用 --skip-ndpresponder。"
    fi

    local tmp_file actual_url
    tmp_file="${STATE_DIR}/ndpresponder.${NDP_ARCH}.tmp"
    if [ -x /usr/local/bin/ndpresponder ] && verify_ndpresponder_hash /usr/local/bin/ndpresponder; then
        say_ok "Existing ndpresponder binary passed SHA256 verification." "现有 ndpresponder 二进制已通过 SHA256 校验。"
    else
        actual_url="${cdn_success_url}${NDP_URL}"
        say_warn "Downloading ndpresponder with SHA256 verification: ${actual_url}" "正在下载并校验 ndpresponder：${actual_url}"
        download_file "$NDP_URL" "$tmp_file" || die "Failed to download ndpresponder." "下载 ndpresponder 失败。"
        if ! verify_ndpresponder_hash "$tmp_file"; then
            rm -f "$tmp_file"
            die "ndpresponder SHA256 verification failed." "ndpresponder SHA256 校验失败。"
        fi
        install -m 0755 "$tmp_file" /usr/local/bin/ndpresponder
        rm -f "$tmp_file"
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        write_ndpresponder_systemd || die "Failed to configure ndpresponder systemd service." "配置 ndpresponder systemd 服务失败。"
    elif command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d ]; then
        write_ndpresponder_openrc || die "Failed to configure ndpresponder OpenRC service." "配置 ndpresponder OpenRC 服务失败。"
    else
        say_warn "No supported service manager found; starting ndpresponder in background for this boot only." "未找到支持的服务管理器，将仅在本次启动中后台运行 ndpresponder。"
        nohup /usr/local/bin/ndpresponder -i "$interface" -n "$ipv6_network" >/var/log/ndpresponder.log 2>&1 &
    fi
}

write_persistence_files() {
    local dir unit_path
    dir="${PERSIST_DIR}/${tunnel_name}"
    mkdir -p "$dir"

    if [ "$OS_FAMILY" = "bsd" ]; then
        cat >"${dir}/bsd-server-up.sh" <<EOF
#!/bin/sh
set -eu
ifconfig ${tunnel_name} >/dev/null 2>&1 || ifconfig ${tunnel_name} create
ifconfig ${tunnel_name} tunnel ${main_ipv4} ${target_address}
ifconfig ${tunnel_name} inet6 ${server_ipv6} ${client_ipv6} prefixlen ${target_mask}
ifconfig ${tunnel_name} mtu ${tunnel_mtu} || true
route -n add -inet6 ${allocated_subnet} -interface ${tunnel_name} 2>/dev/null || true
sysctl net.inet6.ip6.forwarding=1 >/dev/null 2>&1 || true
EOF

        cat >"${dir}/bsd-server-down.sh" <<EOF
#!/bin/sh
set -eu
ifconfig ${tunnel_name} destroy 2>/dev/null || true
EOF

        cat >"${dir}/freebsd-rc.conf.snippet" <<EOF
cloned_interfaces="\${cloned_interfaces} ${tunnel_name}"
ifconfig_${tunnel_name}="tunnel ${main_ipv4} ${target_address} mtu ${tunnel_mtu}"
ifconfig_${tunnel_name}_ipv6="inet6 ${server_ipv6} ${client_ipv6} prefixlen ${target_mask}"
ipv6_gateway_enable="YES"
ipv6_static_routes="\${ipv6_static_routes} 6in4_${tunnel_name}"
ipv6_route_6in4_${tunnel_name}="-net ${allocated_subnet} -interface ${tunnel_name}"
EOF

        cat >"${dir}/openbsd-hostname.${tunnel_name}" <<EOF
tunnel ${main_ipv4} ${target_address}
inet6 ${server_ipv6} ${client_ipv6} ${target_mask}
mtu ${tunnel_mtu}
!route -n add -inet6 ${allocated_subnet} -interface ${tunnel_name}
up
EOF

        cat >"${dir}/bsd-client-up.sh" <<EOF
#!/bin/sh
set -eu
ifconfig gif0 >/dev/null 2>&1 || ifconfig gif0 create
ifconfig gif0 tunnel ${target_address} ${main_ipv4}
ifconfig gif0 inet6 ${client_ipv6} ${server_ipv6} prefixlen ${target_mask}
ifconfig gif0 mtu ${tunnel_mtu} || true
route -n add -inet6 default -interface gif0 2>/dev/null || true
EOF

        chmod 755 "${dir}/bsd-server-up.sh" "${dir}/bsd-server-down.sh" "${dir}/bsd-client-up.sh"
        say_warn "BSD persistence templates were generated but not installed automatically." "已生成 BSD 持久化模板，但未自动安装。"
        return 0
    fi

    cat >"${dir}/server-up.sh" <<EOF
#!/bin/sh
set -eu
ip tunnel show ${tunnel_name} >/dev/null 2>&1 || ip tunnel add ${tunnel_name} mode ${tunnel_mode} remote ${target_address} local ${main_ipv4} ttl ${TUNNEL_TTL}
ip link set ${tunnel_name} mtu ${tunnel_mtu}
ip link set ${tunnel_name} up
ip addr replace ${server_ipv6}/${target_mask} dev ${tunnel_name}
ip route replace ${allocated_subnet} dev ${tunnel_name}
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.proxy_ndp=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.${interface}.proxy_ndp=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.${tunnel_name}.proxy_ndp=1 >/dev/null 2>&1 || true
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t mangle -C FORWARD -o ${tunnel_name} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${tcp_mss} 2>/dev/null || ip6tables -t mangle -A FORWARD -o ${tunnel_name} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${tcp_mss}
    ip6tables -t mangle -C FORWARD -i ${tunnel_name} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${tcp_mss} 2>/dev/null || ip6tables -t mangle -A FORWARD -i ${tunnel_name} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${tcp_mss}
fi
EOF

    cat >"${dir}/server-down.sh" <<EOF
#!/bin/sh
set -eu
if command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -t mangle -D FORWARD -o ${tunnel_name} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${tcp_mss} 2>/dev/null; do :; done
    while ip6tables -t mangle -D FORWARD -i ${tunnel_name} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${tcp_mss} 2>/dev/null; do :; done
fi
ip link set ${tunnel_name} down 2>/dev/null || true
ip tunnel del ${tunnel_name} 2>/dev/null || true
EOF

    cat >"${dir}/client-up.sh" <<EOF
#!/bin/sh
set -eu
ip tunnel show user-ipv6 >/dev/null 2>&1 || ip tunnel add user-ipv6 mode ${tunnel_mode} remote ${main_ipv4} local ${target_address} ttl ${TUNNEL_TTL}
ip link set user-ipv6 mtu ${tunnel_mtu}
ip link set user-ipv6 up
ip addr replace ${client_ipv6}/${target_mask} dev user-ipv6
ip route replace ::/0 dev user-ipv6
EOF

    cat >"${dir}/client-down.sh" <<'EOF'
#!/bin/sh
set -eu
ip link set user-ipv6 down 2>/dev/null || true
ip tunnel del user-ipv6 2>/dev/null || true
EOF

    chmod 755 "${dir}/server-up.sh" "${dir}/server-down.sh" "${dir}/client-up.sh" "${dir}/client-down.sh"

    cat >"${dir}/6in4-${tunnel_name}.service" <<EOF
[Unit]
Description=6in4 tunnel ${tunnel_name}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh ${dir}/server-up.sh
ExecStop=/bin/sh ${dir}/server-down.sh

[Install]
WantedBy=multi-user.target
EOF

    cat >"${dir}/client-user-ipv6.service" <<EOF
[Unit]
Description=6in4 client tunnel user-ipv6
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh /etc/6in4/client-up.sh
ExecStop=/bin/sh /etc/6in4/client-down.sh

[Install]
WantedBy=multi-user.target
EOF

    cat >"${dir}/client-install.sh" <<'EOF'
#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
install -d -m 0755 /etc/6in4
install -m 0755 "${SCRIPT_DIR}/client-up.sh" /etc/6in4/client-up.sh
install -m 0755 "${SCRIPT_DIR}/client-down.sh" /etc/6in4/client-down.sh
install -m 0644 "${SCRIPT_DIR}/client-user-ipv6.service" /etc/systemd/system/client-user-ipv6.service
systemctl daemon-reload
systemctl enable --now client-user-ipv6.service
EOF
    chmod 755 "${dir}/client-install.sh"

    cat >"${dir}/systemd-networkd-${tunnel_name}.netdev" <<EOF
[NetDev]
Name=${tunnel_name}
Kind=${tunnel_mode}
MTUBytes=${tunnel_mtu}

[Tunnel]
Local=${main_ipv4}
Remote=${target_address}
TTL=${TUNNEL_TTL}
EOF

    cat >"${dir}/systemd-networkd-${tunnel_name}.network" <<EOF
[Match]
Name=${tunnel_name}

[Network]
Address=${server_ipv6}/${target_mask}

[Route]
Destination=${allocated_subnet}
EOF

    cat >"${dir}/netplan-${tunnel_name}.yaml" <<EOF
network:
  version: 2
  tunnels:
    ${tunnel_name}:
      mode: ${tunnel_mode}
      local: ${main_ipv4}
      remote: ${target_address}
      ttl: ${TUNNEL_TTL}
      mtu: ${tunnel_mtu}
      addresses:
        - ${server_ipv6}/${target_mask}
      routes:
        - to: ${allocated_subnet}
          scope: link
EOF

    local ifcfg_type
    case "$tunnel_mode" in
    gre) ifcfg_type="GRE" ;;
    sit) ifcfg_type="SIT" ;;
    *) ifcfg_type="IPIP" ;;
    esac

    cat >"${dir}/ifcfg-${tunnel_name}" <<EOF
DEVICE=${tunnel_name}
BOOTPROTO=none
ONBOOT=yes
TYPE=${ifcfg_type}
MY_INNER_IPADDR=${server_ipv6}
PEER_INNER_IPADDR=${client_ipv6}
MY_OUTER_IPADDR=${main_ipv4}
PEER_OUTER_IPADDR=${target_address}
IPV6INIT=yes
IPV6ADDR=${server_ipv6}/${target_mask}
MTU=${tunnel_mtu}
EOF

    if [ "$INSTALL_PERSISTENCE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] && [ "$OS_FAMILY" = "linux" ] && command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        unit_path="/etc/systemd/system/6in4-${tunnel_name}.service"
        cp "${dir}/6in4-${tunnel_name}.service" "$unit_path"
        systemctl daemon-reload
        systemctl enable "6in4-${tunnel_name}.service" || say_warn "Failed to enable 6in4 persistence service." "启用 6in4 持久化服务失败。"
    else
        say_warn "Persistence files were generated but no service was enabled automatically." "已生成持久化配置文件，但没有自动启用服务。"
    fi
}

record_allocation() {
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if [ ! -f "$ALLOCATIONS_FILE" ]; then
        printf 'created_at\tname\tos_family\tmode\tclient_ipv4\tsubnet\tserver_ipv6\tclient_ipv6\tmtu\tmss\tstatus\tdeleted_at\n' >"$ALLOCATIONS_FILE"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tactive\t\n' \
        "$now" "$tunnel_name" "$OS_FAMILY" "$tunnel_mode" "$target_address" "$allocated_subnet" "$server_ipv6" "$client_ipv6" "$tunnel_mtu" "$tcp_mss" >>"$ALLOCATIONS_FILE"
}

write_command_logs() {
    if [ "$OS_FAMILY" = "bsd" ]; then
        append_log_block "$SERVER_LOG" \
            "# server tunnel name: ${tunnel_name}" \
            "# server ipv4: ${main_ipv4}" \
            "# client ipv4: ${target_address}" \
            "# ipv6 subnet: ${server_ipv6}/${target_mask}" \
            "# persistent files: ${PERSIST_DIR}/${tunnel_name}" \
            "ifconfig ${tunnel_name} create" \
            "ifconfig ${tunnel_name} tunnel ${main_ipv4} ${target_address}" \
            "ifconfig ${tunnel_name} inet6 ${server_ipv6} ${client_ipv6} prefixlen ${target_mask}" \
            "ifconfig ${tunnel_name} mtu ${tunnel_mtu}" \
            "route -n add -inet6 ${allocated_subnet} -interface ${tunnel_name}"
        append_log_block "$CLIENT_LOG" \
            "# server ipv4: ${main_ipv4}" \
            "# client ipv4: ${target_address}" \
            "# ipv6 subnet: ${client_ipv6}/${target_mask}" \
            "# Linux client commands and BSD templates are generated under: ${PERSIST_DIR}/${tunnel_name}" \
            "ip tunnel add user-ipv6 mode ${tunnel_mode} remote ${main_ipv4} local ${target_address} ttl ${TUNNEL_TTL}" \
            "ip link set user-ipv6 mtu ${tunnel_mtu}" \
            "ip link set user-ipv6 up" \
            "ip addr add ${client_ipv6}/${target_mask} dev user-ipv6" \
            "ip route add ::/0 dev user-ipv6"
        return 0
    fi

    append_log_block "$SERVER_LOG" \
        "# server tunnel name: ${tunnel_name}" \
        "# server ipv4: ${main_ipv4}" \
        "# client ipv4: ${target_address}" \
        "# ipv6 subnet: ${server_ipv6}/${target_mask}" \
        "# persistent files: ${PERSIST_DIR}/${tunnel_name}" \
        "ip tunnel add ${tunnel_name} mode ${tunnel_mode} remote ${target_address} local ${main_ipv4} ttl ${TUNNEL_TTL}" \
        "ip link set ${tunnel_name} mtu ${tunnel_mtu}" \
        "ip link set ${tunnel_name} up" \
        "ip addr add ${server_ipv6}/${target_mask} dev ${tunnel_name}" \
        "ip route replace ${allocated_subnet} dev ${tunnel_name}"

    append_log_block "$CLIENT_LOG" \
        "# server ipv4: ${main_ipv4}" \
        "# client ipv4: ${target_address}" \
        "# ipv6 subnet: ${client_ipv6}/${target_mask}" \
        "# persistent client scripts are generated under: ${PERSIST_DIR}/${tunnel_name}" \
        "# systemd client install helper: ${PERSIST_DIR}/${tunnel_name}/client-install.sh" \
        "ip tunnel add user-ipv6 mode ${tunnel_mode} remote ${main_ipv4} local ${target_address} ttl ${TUNNEL_TTL}" \
        "ip link set user-ipv6 mtu ${tunnel_mtu}" \
        "ip link set user-ipv6 up" \
        "ip addr add ${client_ipv6}/${target_mask} dev user-ipv6" \
        "ip route add ::/0 dev user-ipv6"
}

health_check() {
    if [ "$DRY_RUN" -eq 1 ]; then
        say_warn "Dry-run mode: health check skipped." "dry-run 模式：已跳过健康检查。"
        return 0
    fi
    [ "$HEALTH_CHECK" -eq 1 ] || return 0
    say_warn "Running tunnel peer health check. It can fail until the client applies its tunnel config." "正在执行隧道对端健康检查。客户端尚未应用配置前，该检查可能失败。"
    if [ "$OS_FAMILY" = "linux" ]; then
        if ping -6 -c 3 -W 2 -I "$tunnel_name" "$client_ipv6" >/tmp/6in4-health.log 2>&1; then
            say_ok "Tunnel peer responded to ping6: ${client_ipv6}" "隧道对端 ping6 已响应：${client_ipv6}"
        else
            say_warn "Tunnel peer did not respond yet. Diagnostics follow." "隧道对端暂未响应。以下为诊断信息。"
            ip -d tunnel show "$tunnel_name" || true
            ip -6 addr show dev "$tunnel_name" || true
            ip -6 route show dev "$tunnel_name" || true
            cat /tmp/6in4-health.log 2>/dev/null || true
        fi
        rm -f /tmp/6in4-health.log
    elif [ "$OS_FAMILY" = "bsd" ]; then
        if ping6 -c 3 -I "$tunnel_name" "$client_ipv6" >/tmp/6in4-health.log 2>&1; then
            say_ok "Tunnel peer responded to ping6: ${client_ipv6}" "隧道对端 ping6 已响应：${client_ipv6}"
        else
            say_warn "Tunnel peer did not respond yet. Diagnostics follow." "隧道对端暂未响应。以下为诊断信息。"
            ifconfig "$tunnel_name" || true
            netstat -rn -f inet6 || true
            cat /tmp/6in4-health.log 2>/dev/null || true
        fi
        rm -f /tmp/6in4-health.log
    fi
}

print_client_instructions() {
    say_warn "This tunnel uses ${tunnel_mode}; MTU ${tunnel_mtu}; TCP MSS ${tcp_mss}." "该隧道使用 ${tunnel_mode}；MTU ${tunnel_mtu}；TCP MSS ${tcp_mss}。"
    say_ok "Install iproute2 on the client, then run:" "请在客户端安装 iproute2，然后执行："
    _blue "ip tunnel add user-ipv6 mode ${tunnel_mode} remote ${main_ipv4} local ${target_address} ttl ${TUNNEL_TTL}"
    _blue "ip link set user-ipv6 mtu ${tunnel_mtu}"
    _blue "ip link set user-ipv6 up"
    _blue "ip addr add ${client_ipv6}/${target_mask} dev user-ipv6"
    _blue "ip route add ::/0 dev user-ipv6"
    say_ok "Client persistence templates:" "客户端持久化模板："
    if [ "$OS_FAMILY" = "bsd" ]; then
        _blue "${PERSIST_DIR}/${tunnel_name}/bsd-client-up.sh"
    else
        _blue "${PERSIST_DIR}/${tunnel_name}/client-up.sh"
        _blue "${PERSIST_DIR}/${tunnel_name}/client-user-ipv6.service"
        _blue "${PERSIST_DIR}/${tunnel_name}/client-install.sh"
    fi
    say_ok "No passwords or private keys are generated by this script." "此脚本不会生成密码或私钥。"
}

run_main() {
    prepare_locale
    parse_args "$@"
    apply_runtime_path_defaults
    ensure_root
    prepare_dirs
    acquire_lock
    migrate_legacy_state
    detect_system
    detect_package_manager
    validate_inputs
    ensure_dependencies
    statistics_of_run_times
    detect_china
    select_cdn
    detect_arch
    collect_network_info
    target_mask=$(calculate_target_prefix "$ipv6_prefixlen" "$target_mask")
    allocated_subnet=$(allocate_subnet)
    tunnel_name=$(next_tunnel_name)
    address_info=$(derive_subnet_addresses "$allocated_subnet")
    server_ipv6=$(printf '%s\n' "$address_info" | sed -n '1p')
    client_ipv6=$(printf '%s\n' "$address_info" | sed -n '2p')
    calculate_mtu

    say_ok "Allocated subnet: ${allocated_subnet}" "已分配子网：${allocated_subnet}"
    say_ok "Server tunnel name: ${tunnel_name}" "服务端隧道名称：${tunnel_name}"

    if [ "$OS_FAMILY" = "linux" ]; then
        install_ndpresponder
        configure_linux_tunnel
    else
        configure_bsd_tunnel
    fi

    record_allocation
    write_persistence_files
    write_command_logs
    health_check
    print_client_instructions
    say_ok "Server log: ${SERVER_LOG}" "服务端日志：${SERVER_LOG}"
    say_ok "Client log: ${CLIENT_LOG}" "客户端日志：${CLIENT_LOG}"
}

run_main "$@"
