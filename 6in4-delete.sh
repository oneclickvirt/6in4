#!/usr/bin/env bash
# Delete tunnels created by 6in4.sh.

set -uo pipefail

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
  ./6in4-delete.sh <tunnel_name>
  ./6in4-delete.sh --all
  ./6in4-delete.sh --list
  ./6in4-delete.sh --dry-run --all

Environment:
  SIXIN4_STATE_DIR  Default: /var/lib/6in4
  6IN4_STATE_DIR    Accepted through env(1) for compatibility
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
STATE_DIR="${env_state_dir:-/var/lib/6in4}"
ALLOCATIONS_FILE="${STATE_DIR}/allocations.tsv"
PERSIST_DIR="${STATE_DIR}/persistent"
LOCK_FILE="${STATE_DIR}/6in4.lock"
LOCK_DIR=""
DELETE_ALL=0
LIST_ONLY=0
TARGET_NAME=""
OS_FAMILY=""
DRY_RUN=0

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

detect_system() {
    if [ "$DRY_RUN" -eq 1 ]; then
        OS_FAMILY="linux"
        return 0
    fi
    case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux) OS_FAMILY="linux" ;;
    FreeBSD | OpenBSD | NetBSD | DragonFly) OS_FAMILY="bsd" ;;
    *) OS_FAMILY="unix" ;;
    esac
}

refresh_runtime_paths() {
    ALLOCATIONS_FILE="${STATE_DIR}/allocations.tsv"
    PERSIST_DIR="${STATE_DIR}/persistent"
    LOCK_FILE="${STATE_DIR}/6in4.lock"
}

apply_runtime_path_defaults() {
    if [ "$DRY_RUN" -eq 1 ] && [ -z "$env_state_dir" ]; then
        STATE_DIR="${TMPDIR:-/tmp}/6in4-dry-run/state"
        refresh_runtime_paths
    fi
}

acquire_lock() {
    mkdir -p "$STATE_DIR" || die "Failed to create state directory." "创建状态目录失败。"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            die "Another 6in4 operation is running." "另一个 6in4 操作正在运行。"
        fi
    else
        LOCK_DIR="${STATE_DIR}/.lock"
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            die "Another 6in4 operation is running, or a stale lock exists." "另一个 6in4 操作正在运行，或存在过期锁。"
        fi
        trap cleanup_lock EXIT INT TERM
    fi
}

parse_args() {
    [ "$#" -gt 0 ] || {
        usage
        exit 1
    }
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --all)
            DELETE_ALL=1
            shift
            ;;
        --list)
            LIST_ONLY=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            die "Unknown option: $1" "未知参数：$1"
            ;;
        *)
            TARGET_NAME="$1"
            shift
            ;;
        esac
    done
}

list_active() {
    if [ ! -f "$ALLOCATIONS_FILE" ]; then
        say_warn "No allocation file exists at ${ALLOCATIONS_FILE}." "分配记录不存在：${ALLOCATIONS_FILE}"
        return 0
    fi
    awk -F '\t' 'NR == 1 {next} $11 == "active" {print $2 "\t" $5 "\t" $6 "\t" $7 "\t" $8}' "$ALLOCATIONS_FILE"
}

active_names() {
    [ -f "$ALLOCATIONS_FILE" ] || return 0
    awk -F '\t' 'NR == 1 {next} $11 == "active" {print $2}' "$ALLOCATIONS_FILE"
}

is_safe_tunnel_name() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
    [[ "$name" != *..* ]] || return 1
    [[ "$name" != */* ]] || return 1
}

tunnel_exists() {
    local name="$1"
    [ "$DRY_RUN" -eq 0 ] || return 1
    if [ "$OS_FAMILY" = "linux" ]; then
        ip link show dev "$name" >/dev/null 2>&1
    elif [ "$OS_FAMILY" = "bsd" ]; then
        ifconfig "$name" >/dev/null 2>&1
    else
        return 1
    fi
}

allocation_mss() {
    local name="$1"
    [ -f "$ALLOCATIONS_FILE" ] || {
        printf '%s\n' "1220"
        return 0
    }
    awk -F '\t' -v name="$name" 'NR > 1 && $2 == name && $11 == "active" {print $10; found=1; exit} END {if (!found) print "1220"}' "$ALLOCATIONS_FILE"
}

delete_linux_tunnel() {
    local name="$1"
    local mss
    mss=$(allocation_mss "$name")
    [[ "$mss" =~ ^[0-9]+$ ]] || mss=1220
    if tunnel_exists "$name"; then
        _blue "ip link set ${name} down"
        ip link set "$name" down 2>/dev/null || true
        _blue "ip tunnel del ${name}"
        ip tunnel del "$name" 2>/dev/null || true
    else
        say_warn "Tunnel ${name} does not exist in the kernel; state will still be released." "内核中不存在隧道 ${name}；仍将释放状态记录。"
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -t mangle -D FORWARD -o "$name" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss" 2>/dev/null; do :; done
        while ip6tables -t mangle -D FORWARD -i "$name" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss" 2>/dev/null; do :; done
    fi
}

delete_bsd_tunnel() {
    local name="$1"
    if tunnel_exists "$name"; then
        _blue "ifconfig ${name} destroy"
        ifconfig "$name" destroy 2>/dev/null || true
    else
        say_warn "Tunnel ${name} does not exist in the kernel; state will still be released." "内核中不存在隧道 ${name}；仍将释放状态记录。"
    fi
}

disable_persistence() {
    local name="$1"
    local unit="6in4-${name}.service"
    if [ "$DRY_RUN" -eq 0 ] && command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/${unit}" ]; then
        systemctl disable --now "$unit" 2>/dev/null || true
        rm -f "/etc/systemd/system/${unit}"
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -rf "${PERSIST_DIR:?}/${name}"
}

mark_deleted() {
    local name="$1"
    local tmp now
    [ -f "$ALLOCATIONS_FILE" ] || return 0
    tmp="${ALLOCATIONS_FILE}.tmp.$$"
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    awk -F '\t' -v OFS='\t' -v name="$name" -v now="$now" '
        NR == 1 {
            if (NF < 12) {
                print $0 "\tdeleted_at"
            } else {
                print
            }
            next
        }
        $2 == name && $11 == "active" {
            $11 = "deleted"
            $12 = now
        }
        { print }
    ' "$ALLOCATIONS_FILE" >"$tmp" && mv -f "$tmp" "$ALLOCATIONS_FILE"
}

delete_one() {
    local name="$1"
    [ -n "$name" ] || return 0
    is_safe_tunnel_name "$name" || die "Refusing unsafe tunnel name: ${name}" "拒绝不安全的隧道名称：${name}"
    if [ "$DRY_RUN" -eq 1 ]; then
        say_warn "Dry-run: would delete tunnel ${name}, disable persistence, and mark its allocation deleted." "dry-run：将会删除隧道 ${name}、停用持久化并标记分配记录为 deleted。"
        return 0
    fi
    if [ "$OS_FAMILY" = "linux" ]; then
        delete_linux_tunnel "$name"
    elif [ "$OS_FAMILY" = "bsd" ]; then
        delete_bsd_tunnel "$name"
    else
        say_warn "Unsupported platform for kernel cleanup; only state will be released." "当前平台不支持内核清理；仅释放状态记录。"
    fi
    disable_persistence "$name"
    mark_deleted "$name"
    say_ok "Deleted tunnel: ${name}" "已删除隧道：${name}"
}

main() {
    parse_args "$@"
    apply_runtime_path_defaults
    ensure_root
    detect_system
    acquire_lock
    if [ "$LIST_ONLY" -eq 1 ]; then
        list_active
        exit 0
    fi
    if [ "$DELETE_ALL" -eq 1 ]; then
        active_names | while read -r name; do
            delete_one "$name"
        done
        exit 0
    fi
    [ -n "$TARGET_NAME" ] || die "Tunnel name is required." "必须提供隧道名称。"
    delete_one "$TARGET_NAME"
}

main "$@"
