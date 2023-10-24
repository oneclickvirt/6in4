#!/bin/bash
# from
# https://github.com/oneclickvirt/6in4
# 2023.10.24

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
export DEBIAN_FRONTEND=noninteractive
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    echo "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    echo "Locale set to $utf8_locale"
fi
if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi
temp_file_apt_fix="/tmp/apt_fix.txt"
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch")
PACKAGE_UPDATE=("! apt-get update && apt-get --fix-broken install -y && apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "pacman -Sy")
PACKAGE_INSTALL=("apt-get -y install" "apt-get -y install" "yum -y install" "yum -y install" "yum -y install" "pacman -Sy --noconfirm --needed")
PACKAGE_REMOVE=("apt-get -y remove" "apt-get -y remove" "yum -y remove" "yum -y remove" "yum -y remove" "pacman -Rsc --noconfirm")
PACKAGE_UNINSTALL=("apt-get -y autoremove" "apt-get -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove" "")
CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')" "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)")
SYS="${CMD[0]}"
[[ -n $SYS ]] || exit 1
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done

target_address="${1:-None}"

if [ "${target_address}" == "None" ]; then
    _red "Client's IPV4 address not set"
    _red "未设置客户端的IPV4地址"
    exit 1
fi

statistics_of_run-times() {
    COUNT=$(
        curl -4 -ksm1 "https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2FspiritLHLS%2Fdocker&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=&edge_flat=true" 2>&1 ||
            curl -6 -ksm1 "https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2FspiritLHLS%2Fdocker&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=&edge_flat=true" 2>&1
    ) &&
        TODAY=$(expr "$COUNT" : '.*\s\([0-9]\{1,\}\)\s/.*') && TOTAL=$(expr "$COUNT" : '.*/\s\([0-9]\{1,\}\)\s.*')
}

check_update() {
    _yellow "Updating package management sources"
    if command -v apt-get >/dev/null 2>&1; then
        apt_update_output=$(apt-get update 2>&1)
        echo "$apt_update_output" >"$temp_file_apt_fix"
        if grep -q 'NO_PUBKEY' "$temp_file_apt_fix"; then
            public_keys=$(grep -oE 'NO_PUBKEY [0-9A-F]+' "$temp_file_apt_fix" | awk '{ print $2 }')
            joined_keys=$(echo "$public_keys" | paste -sd " ")
            _yellow "No Public Keys: ${joined_keys}"
            apt-key adv --keyserver keyserver.ubuntu.com --recv-keys ${joined_keys}
            apt-get update
            if [ $? -eq 0 ]; then
                _green "Fixed"
            fi
        fi
        rm "$temp_file_apt_fix"
    else
        ${PACKAGE_UPDATE[int]}
    fi
}



is_private_ipv6() {
    local address=$1
    # 输入不含:符号
    if [[ $ip_address != *":"* ]]; then
        return 0
    fi
    # 输入为空
    if [[ -z $ip_address ]]; then
        return 0
    fi
    # 检查IPv6地址是否以fe80开头（链接本地地址）
    if [[ $address == fe80:* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以fc00或fd00开头（唯一本地地址）
    if [[ $address == fc00:* || $address == fd00:* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以2001:db8开头（文档前缀）
    if [[ $address == 2001:db8* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以::1开头（环回地址）
    if [[ $address == ::1 ]]; then
        return 0
    fi
    # 检查IPv6地址是否以::ffff:开头（IPv4映射地址）
    if [[ $address == ::ffff:* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以2002:开头（6to4隧道地址）
    if [[ $address == 2002:* ]]; then
        return 0
    fi
    # 检查IPv6地址是否以2001:开头（Teredo隧道地址）
    if [[ $address == 2001:* ]]; then
        return 0
    fi
    # 其他情况为公网地址
    return 1
}

check_ipv6() {
    IPV6=$(ip -6 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)
    if is_private_ipv6 "$IPV6"; then # 由于是内网IPV6地址，需要通过API获取外网地址
        IPV6=""
        API_NET=("ipv6.ip.sb" "https://ipget.net" "ipv6.ping0.cc" "https://api.my-ip.io/ip" "https://ipv6.icanhazip.com")
        for p in "${API_NET[@]}"; do
            response=$(curl -sLk6m8 "$p" | tr -d '[:space:]')
            if [ $? -eq 0 ] && ! (echo "$response" | grep -q "error"); then
                IPV6="$response"
                break
            fi
            sleep 1
        done
    fi
    echo $IPV6 >/usr/local/bin/6in4_check_ipv6
}

check_cdn() {
    local o_url=$1
    for cdn_url in "${cdn_urls[@]}"; do
        if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN"
    else
        _yellow "No CDN available, no use CDN"
    fi
}

get_system_arch() {
    local sysarch="$(uname -m)"
    if [ "${sysarch}" = "unknown" ] || [ "${sysarch}" = "" ]; then
        local sysarch="$(arch)"
    fi
    # 根据架构信息设置系统位数并下载文件,其余 * 包括了 x86_64
    case "${sysarch}" in
    "i386" | "i686" | "x86_64")
        system_arch="x86"
        ;;
    "armv7l" | "armv8" | "armv8l" | "aarch64")
        system_arch="arch"
        ;;
    *)
        system_arch=""
        ;;
    esac
}

check_china() {
    _yellow "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            _yellow "根据ipapi.co提供的信息，当前IP可能在中国"
            read -e -r -p "是否选用中国镜像完成相关组件安装? ([y]/n) " input
            case $input in
            [yY][eE][sS] | [yY])
                echo "使用中国镜像"
                CN=true
                ;;
            [nN][oO] | [nN])
                echo "不使用中国镜像"
                ;;
            *)
                echo "使用中国镜像"
                CN=true
                ;;
            esac
        else
            if [[ $? -ne 0 ]]; then
                if [[ $(curl -m 6 -s cip.cc) =~ "中国" ]]; then
                    _yellow "根据cip.cc提供的信息，当前IP可能在中国"
                    read -e -r -p "是否选用中国镜像完成相关组件安装? [Y/n] " input
                    case $input in
                    [yY][eE][sS] | [yY])
                        echo "使用中国镜像"
                        CN=true
                        ;;
                    [nN][oO] | [nN])
                        echo "不使用中国镜像"
                        ;;
                    *)
                        echo "不使用中国镜像"
                        ;;
                    esac
                fi
            fi
        fi
    fi
}

update_sysctl() {
  sysctl_config="$1"
  if grep -q "^$sysctl_config" /etc/sysctl.conf; then
    if grep -q "^#$sysctl_config" /etc/sysctl.conf; then
      sed -i "s/^#$sysctl_config/$sysctl_config/" /etc/sysctl.conf
    fi
  else
    echo "$sysctl_config" >> /etc/sysctl.conf
  fi
}


if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi
rebuild_cloud_init
statistics_of_run-times
_green "脚本当天运行次数:${TODAY}，累计运行次数:${TOTAL}"
check_update
if ! command -v sudo >/dev/null 2>&1; then
    _yellow "Installing sudo"
    ${PACKAGE_INSTALL[int]} sudo
fi
if ! command -v curl >/dev/null 2>&1; then
    _yellow "Installing curl"
    ${PACKAGE_INSTALL[int]} curl
fi
if ! command -v wget >/dev/null 2>&1; then
    _yellow "Installing wget"
    ${PACKAGE_INSTALL[int]} wget
fi
if ! command -v jq >/dev/null 2>&1; then
    _yellow "Installing jq"
    ${PACKAGE_INSTALL[int]} jq
fi
if ! command -v dos2unix >/dev/null 2>&1; then
    _yellow "Installing dos2unix"
    ${PACKAGE_INSTALL[int]} dos2unix
fi
if ! command -v lshw >/dev/null 2>&1; then
    _yellow "Installing lshw"
    ${PACKAGE_INSTALL[int]} lshw
fi
if ! command -v ipcalc >/dev/null 2>&1; then
    _yellow "Installing ipcalc"
    ${PACKAGE_INSTALL[int]} ipcalc
fi
if ! command -v bc >/dev/null 2>&1; then
    _yellow "Installing bc"
    ${PACKAGE_INSTALL[int]} bc
fi
${PACKAGE_INSTALL[int]} iproute2
${PACKAGE_INSTALL[int]} net-tools
check_china
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn3.spiritlhl.net/" "http://cdn1.spiritlhl.net/" "https://ghproxy.com/" "http://cdn2.spiritlhl.net/")
check_cdn_file
get_system_arch
${PACKAGE_INSTALL[int]} openssl

# 检测物理接口
interface_1=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '1p')
interface_2=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '2p')
check_interface

# 检测主IPV4相关信息
if [ ! -f /usr/local/bin/6in4_main_ipv4 ]; then
    main_ipv4=$(ip -4 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)
    echo "$main_ipv4" >/usr/local/bin/6in4_main_ipv4
fi
# 提取主IPV4地址
main_ipv4=$(cat /usr/local/bin/6in4_main_ipv4)
if [ ! -f /usr/local/bin/6in4_ipv4_address ]; then
    ipv4_address=$(ip addr show | awk '/inet .*global/ && !/inet6/ {print $2}' | sed -n '1p')
    echo "$ipv4_address" >/usr/local/bin/6in4_ipv4_address
fi
# 提取IPV4地址 含子网长度
ipv4_address=$(cat /usr/local/bin/6in4_ipv4_address)
if [ ! -f /usr/local/bin/6in4_ipv4_gateway ]; then
    ipv4_gateway=$(ip route | awk '/default/ {print $3}' | sed -n '1p')
    echo "$ipv4_gateway" >/usr/local/bin/6in4_ipv4_gateway
fi
# 提取IPV4网关
ipv4_gateway=$(cat /usr/local/bin/6in4_ipv4_gateway)
if [ ! -f /usr/local/bin/6in4_ipv4_subnet ]; then
    ipv4_subnet=$(ipcalc -n "$ipv4_address" | grep -oP 'Netmask:\s+\K.*' | awk '{print $1}')
    echo "$ipv4_subnet" >/usr/local/bin/6in4_ipv4_subnet
fi
# 提取Netmask
ipv4_subnet=$(cat /usr/local/bin/6in4_ipv4_subnet)
# 提取子网掩码
ipv4_prefixlen=$(echo "$ipv4_address" | cut -d '/' -f 2)

# 检测IPV6相关的信息
if [ ! -f /usr/local/bin/6in4_check_ipv6 ] || [ ! -s /usr/local/bin/6in4_check_ipv6 ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/6in4_check_ipv6)" = "" ]; then
    check_ipv6
fi
if [ ! -f /usr/local/bin/6in4_ipv6_prefixlen ] || [ ! -s /usr/local/bin/6in4_ipv6_prefixlen ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/6in4_ipv6_prefixlen)" = "" ]; then
    ipv6_prefixlen=$(ifconfig ${interface} | grep -oP 'prefixlen \K\d+' | head -n 1)
    echo "$ipv6_prefixlen" >/usr/local/bin/6in4_ipv6_prefixlen
fi
if [ ! -f /usr/local/bin/6in4_ipv6_gateway ] || [ ! -s /usr/local/bin/6in4_ipv6_gateway ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/6in4_ipv6_gateway)" = "" ]; then
    output=$(ip -6 route show | awk '/default via/{print $3}')
    num_lines=$(echo "$output" | wc -l)
    ipv6_gateway=""
    if [ $num_lines -eq 1 ]; then
        ipv6_gateway="$output"
    elif [ $num_lines -ge 2 ]; then
        non_fe80_lines=$(echo "$output" | grep -v '^fe80')
        if [ -n "$non_fe80_lines" ]; then
            ipv6_gateway=$(echo "$non_fe80_lines" | head -n 1)
        else
            ipv6_gateway=$(echo "$output" | head -n 1)
        fi
    fi
    echo "$ipv6_gateway" >/usr/local/bin/6in4_ipv6_gateway
    # 判断fe80是否已加白
    if [[ $ipv6_gateway == fe80* ]]; then
        ipv6_gateway_fe80="Y"
    else
        ipv6_gateway_fe80="N"
    fi
fi
if [ ! -f /usr/local/bin/6in4_fe80_address ] || [ ! -s /usr/local/bin/6in4_fe80_address ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/6in4_fe80_address)" = "" ]; then
    fe80_address=$(ip -6 addr show dev $interface | awk '/inet6 fe80/ {print $2}')
    echo "$fe80_address" >/usr/local/bin/6in4_fe80_address
fi
ipv6_address=$(cat /usr/local/bin/6in4_check_ipv6)
ipv6_address_without_last_segment="${ipv6_address%:*}:"
ipv6_prefixlen=$(cat /usr/local/bin/6in4_ipv6_prefixlen)
ipv6_gateway=$(cat /usr/local/bin/6in4_ipv6_gateway)
fe80_address=$(cat /usr/local/bin/6in4_fe80_address)

# 正式映射
if [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ] && [ ! -z "$interface" ] && [ ! -z "$ipv4_address" ] && [ ! -z "$ipv4_prefixlen" ] && [ ! -z "$ipv4_gateway" ] && [ ! -z "$ipv4_subnet" ] && [ ! -z "$fe80_address" ]; then
    identifier="2333"
    if [[ "${ipv6_address_without_last_segment: -2}" == "::" ]]; then
        new_subnet="${ipv6_address_without_last_segment%::*}:${identifier}::/80"
    else
        echo "The last two digits of the IPV6 subnet prefix are not ::"
        exit 1
    fi

    ip tunnel add server-ipv6 mode sit remote "${target_address}" local "${main_ipv4}" ttl 255
    ip link set server-ipv6 up
    ip addr add "${ipv6_address_without_last_segment%::*}:${identifier}::1/80" dev server-ipv6
    ip route add "${ipv6_address_without_last_segment%::*}:${identifier}::/80" dev server-ipv6
    sysctl_path=$(which sysctl)

    # 设置允许IPV6转发
    echo "net.ipv6.conf.all.forwarding = 1" >>/etc/sysctl.conf
    $sysctl_path -w net.ipv6.conf.all.forwarding=1
    $sysctl_path -w net.ipv6.conf.all.proxy_ndp=1
    $sysctl_path -w net.ipv6.conf.default.proxy_ndp=1
    $sysctl_path -w net.ipv6.conf.docker0.proxy_ndp=1
    $sysctl_path -w net.ipv6.conf.${interface}.proxy_ndp=1
    if [ "$status_he" = true ]; then
        $sysctl_path -w net.ipv6.conf.he-ipv6.proxy_ndp=1
    fi
    $sysctl_path -f
    if [ ! -f "/usr/local/bin/check-dns.sh" ]; then
        wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/docker/main/extra_scripts/check-dns.sh -O /usr/local/bin/check-dns.sh
        wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/docker/main/extra_scripts/check-dns.service -O /etc/systemd/system/check-dns.service
        chmod +x /usr/local/bin/check-dns.sh
        chmod +x /etc/systemd/system/check-dns.service
        systemctl daemon-reload
        systemctl enable check-dns.service
        systemctl start check-dns.service
    fi
fi
_green "客户端的宿主机需要安装iproute2包 - The client's host needs to have the iproute2 package installed"
_green "The following commands are to be executed on the client:"
_green "以下是要在客户端上执行的命令:"
echo "ip tunnel add he-ipv6 mode sit remote ${main_ipv4} local ${target_address} ttl 255"
echo "ip link set he-ipv6 up"
echo "ip addr add ${ipv6_address_without_last_segment%::*}:${identifier}::2/80 dev he-ipv6"
echo "ip route add ::/0 dev he-ipv6"
