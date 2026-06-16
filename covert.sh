#!/usr/bin/env bash
# Convert /etc/network/interfaces tunnel syntax between ifupdown and ifupdown2.

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }

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

die() {
    say_error "$1" "$2"
    exit 1
}

ensure_root() {
    if [ "$(id -u)" != "0" ]; then
        die "This script must be run as root." "此脚本必须以 root 权限运行。"
    fi
}

detect_debian_like() {
    if [ -r /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        case " ${ID:-} ${ID_LIKE:-} " in
        *" debian "* | *" ubuntu "*) return 0 ;;
        esac
    fi
    return 1
}

install_package() {
    local package="$1"
    if ! command -v apt-get >/dev/null 2>&1; then
        return 1
    fi
    apt-get update
    apt-get install -y "$package"
}

detect_ifupdown_status() {
    if dpkg -s ifupdown2 >/dev/null 2>&1; then
        printf '%s\n' 2
    elif dpkg -s ifupdown >/dev/null 2>&1; then
        printf '%s\n' 1
    else
        printf '%s\n' 0
    fi
}

sed_in_place() {
    local expression="$1"
    local file="$2"
    sed -i.bak -E "$expression" "$file"
    rm -f "${file}.bak"
}

validate_interfaces() {
    if command -v ifquery >/dev/null 2>&1; then
        if ifquery --help 2>&1 | grep -q -- '--check'; then
            ifquery --check --all
            return $?
        fi
    fi
    if command -v ifup >/dev/null 2>&1; then
        ifup --no-act -a
        return $?
    fi
    say_warn "No ifupdown validation command was found; only file syntax conversion was performed." "未找到 ifupdown 验证命令；仅完成文件语法转换。"
    return 0
}

restart_networking() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart networking
    elif [ -x /etc/init.d/networking ]; then
        /etc/init.d/networking restart
    elif command -v service >/dev/null 2>&1; then
        service networking restart
    else
        say_warn "No networking restart command was found. Please restart networking manually." "未找到网络重启命令，请手动重启 networking。"
        return 0
    fi
}

main() {
    ensure_root
    detect_debian_like || die "Only Debian/Ubuntu style ifupdown systems can be converted automatically." "仅 Debian/Ubuntu 风格的 ifupdown 系统可自动转换。"
    [ -f /etc/network/interfaces ] || die "/etc/network/interfaces does not exist." "/etc/network/interfaces 不存在。"

    local status backup
    status=$(detect_ifupdown_status)
    backup="/etc/network/interfaces.6in4.$(date +%Y%m%d%H%M%S).bak"
    cp /etc/network/interfaces "$backup" || die "Failed to back up /etc/network/interfaces." "备份 /etc/network/interfaces 失败。"

    if command -v chattr >/dev/null 2>&1; then
        chattr -i /etc/network/interfaces 2>/dev/null || true
    fi

    if [ "$status" = "1" ]; then
        if grep -q "mode sit" /etc/network/interfaces; then
            sed_in_place '/^[[:space:]]*mode[[:space:]]+sit[[:space:]]*$/d' /etc/network/interfaces
            sed_in_place 's/^([[:space:]]*)tunnel([[:space:]]+)/\1v4tunnel\2/' /etc/network/interfaces
            say_ok "Converted ifupdown2 tunnel syntax to ifupdown v4tunnel syntax." "已将 ifupdown2 隧道语法转换为 ifupdown v4tunnel 语法。"
        else
            say_warn "No mode sit entry was found; nothing to convert for ifupdown." "未发现 mode sit 项；ifupdown 无需转换。"
        fi
    elif [ "$status" = "2" ]; then
        if grep -q "v4tunnel" /etc/network/interfaces; then
            sed_in_place 's/^([[:space:]]*)v4tunnel([[:space:]]+)/\1tunnel\2/' /etc/network/interfaces
            awk '
                { print }
                /^[[:space:]]*tunnel[[:space:]]/ {
                    getline nextline
                    if (nextline !~ /^[[:space:]]*mode[[:space:]]+sit/) {
                        print "    mode sit"
                    }
                    if (nextline != "") {
                        print nextline
                    }
                }
            ' /etc/network/interfaces > /etc/network/interfaces.6in4.tmp && mv /etc/network/interfaces.6in4.tmp /etc/network/interfaces
            say_ok "Converted ifupdown v4tunnel syntax to ifupdown2 tunnel syntax." "已将 ifupdown v4tunnel 语法转换为 ifupdown2 tunnel 语法。"
        else
            say_warn "No v4tunnel entry was found; nothing to convert for ifupdown2." "未发现 v4tunnel 项；ifupdown2 无需转换。"
        fi
    else
        say_warn "Neither ifupdown nor ifupdown2 is installed; trying ifupdown first." "未安装 ifupdown 或 ifupdown2；将优先尝试安装 ifupdown。"
        if install_package ifupdown; then
            sed_in_place '/^[[:space:]]*mode[[:space:]]+sit[[:space:]]*$/d' /etc/network/interfaces
            sed_in_place 's/^([[:space:]]*)tunnel([[:space:]]+)/\1v4tunnel\2/' /etc/network/interfaces
        elif install_package ifupdown2; then
            sed_in_place 's/^([[:space:]]*)v4tunnel([[:space:]]+)/\1tunnel\2/' /etc/network/interfaces
            sed_in_place '/^[[:space:]]*tunnel[[:space:]]/a\    mode sit' /etc/network/interfaces
        else
            cp "$backup" /etc/network/interfaces
            die "Failed to install ifupdown or ifupdown2." "安装 ifupdown 或 ifupdown2 失败。"
        fi
    fi

    if ! validate_interfaces; then
        cp "$backup" /etc/network/interfaces
        die "Network interface validation failed; original file was restored from ${backup}." "网络配置验证失败；已从 ${backup} 恢复原文件。"
    fi

    restart_networking || {
        cp "$backup" /etc/network/interfaces
        die "Networking restart failed; original file was restored from ${backup}." "重启 networking 失败；已从 ${backup} 恢复原文件。"
    }
    say_ok "Conversion completed and networking validation passed. Backup: ${backup}" "转换完成且网络验证通过。备份文件：${backup}"
}

main "$@"
