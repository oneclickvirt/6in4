#!/bin/bash
# from
# https://github.com/oneclickvirt/6in4
# 2024.01.11

cd /root >/dev/null 2>&1
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

statistics_of_run-times() {
    COUNT=$(
        curl -4 -ksm1 "https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2Foneclickvirt%2F6in4&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=&edge_flat=true" 2>&1 ||
            curl -6 -ksm1 "https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2Foneclickvirt%2F6in4&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=&edge_flat=true" 2>&1
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

is_ipv4() {
    local ip=$1
    local regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    if [[ $ip =~ $regex ]]; then
        return 0 # 符合IPv4格式
    else
        return 1 # 不符合IPv4格式
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
        echo "$sysctl_config" >>/etc/sysctl.conf
    fi
}

check_interface() {
    if [ -z "$interface_2" ]; then
        interface=${interface_1}
        return
    elif [ -n "$interface_1" ] && [ -n "$interface_2" ]; then
        if ! grep -q "$interface_1" "/etc/network/interfaces" && ! grep -q "$interface_2" "/etc/network/interfaces" && [ -f "/etc/network/interfaces.d/50-cloud-init" ]; then
            if grep -q "$interface_1" "/etc/network/interfaces.d/50-cloud-init" || grep -q "$interface_2" "/etc/network/interfaces.d/50-cloud-init"; then
                if ! grep -q "$interface_1" "/etc/network/interfaces.d/50-cloud-init" && grep -q "$interface_2" "/etc/network/interfaces.d/50-cloud-init"; then
                    interface=${interface_2}
                    return
                elif ! grep -q "$interface_2" "/etc/network/interfaces.d/50-cloud-init" && grep -q "$interface_1" "/etc/network/interfaces.d/50-cloud-init"; then
                    interface=${interface_1}
                    return
                fi
            fi
        fi
        if grep -q "$interface_1" "/etc/network/interfaces"; then
            interface=${interface_1}
            return
        elif grep -q "$interface_2" "/etc/network/interfaces"; then
            interface=${interface_2}
            return
        else
            interfaces_list=$(ip addr show | awk '/^[0-9]+: [^lo]/ {print $2}' | cut -d ':' -f 1)
            interface=""
            for iface in $interfaces_list; do
                if [[ "$iface" = "$interface_1" || "$iface" = "$interface_2" ]]; then
                    interface="$iface"
                fi
            done
            if [ -z "$interface" ]; then
                interface="eth0"
            fi
            return
        fi
    else
        interface="eth0"
        return
    fi
    _red "Physical interface not found, exit execution"
    _red "找不到物理接口，退出执行"
    exit 1
}

calculate_subnets() {
    local subnets
    local subnet_prefix
    local total_prefix
    total_prefix=$1
    subnet_prefix=$2
    subnets=$(($subnet_prefix - $total_prefix))
    if [ $subnets -gt 16 ]; then
        subnet_prefix=${total_prefix}
        ((subnet_prefix += 8 - ($total_prefix % 8)))
    fi
    echo "$subnet_prefix"
}

ipv6_tunnel() {
    if [[ "${tunnel_mode}" == "gre" ]]; then
        gre_info=$(modinfo gre)
        if [ ! -n "$gre_info" ]; then
            _red "No match gre in kernal. Use sit mode"
            tunnel_mode="sit"
        fi
    elif [[ "${tunnel_mode}" == "ipip" ]]; then
        ipip_info=$(modinfo ipip)
        if [ ! -n "$ipip_info" ]; then
            _red "No match ipip in kernal. Use sit mode"
            tunnel_mode="sit"
        fi
    fi
    if [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ] && [ ! -z "$interface" ] && [ ! -z "$ipv4_address" ] && [ ! -z "$ipv4_prefixlen" ] && [ ! -z "$ipv4_gateway" ] && [ ! -z "$ipv4_subnet" ]; then
        # 获取宿主机IPV6上指定大小分区的第二个子网(因为第一个子网将包含宿主机本来就绑定了的IPV6地址)的起始IPV6地址0000结尾那个
        # echo "sipcalc --v6split=${target_mask} ${ipv6_address}/${ipv6_prefixlen} | awk '/Network/{n++} n==2' | awk '{print $3}' | grep -v '^$'"
        if [ ! -f /usr/local/bin/6in4_usable_subnets ]; then
            sipcalc --v6split=${target_mask} ${ipv6_address}/${ipv6_prefixlen} > /usr/local/bin/6in4_usable_subnets
            sed -i '1,5d' /usr/local/bin/6in4_usable_subnets
            head -n -2 /usr/local/bin/6in4_usable_subnets > temp.text
            mv temp.text /usr/local/bin/6in4_usable_subnets
        fi
        ipv6_subnets_usable_num=$(cat /usr/local/bin/6in4_usable_subnets | grep "^Network" | wc -l)
        _blue "The number of ${target_mask} subnets available: ${ipv6_subnets_usable_num}"
        ipv6_subnet_2=$(cat /usr/local/bin/6in4_usable_subnets | head -n 2 | awk '{print $3}' | grep -v '^$')
        # ipv6_subnet_2=$( sipcalc --v6split=64 2001:db8::/48 | awk '/Network/{n++} n==2' | awk '{print $3}' | grep -v '^$' )
        # 使用过的子网不删除未使用记录，记录到已使用文件中
        cat /usr/local/bin/6in4_usable_subnets | head -n 2 | tee -a /usr/local/bin/6in4_used_subnets
        sed -i '1,2d' /usr/local/bin/6in4_usable_subnets
        ipv6_subnets_used_num=$(cat /usr/local/bin/6in4_used_subnets | grep "^Network" | wc -l)
        _blue "The number of ${target_mask} subnets used: ${ipv6_subnets_used_num}"
        # 切除最后4位地址(切除0000)，只保留前缀方便后续处理
        ipv6_subnet_2_without_last_segment="${ipv6_subnet_2%:*}:"
        if [ -n "$ipv6_subnet_2_without_last_segment" ]; then
            :
        else
            _red "The ipv6 subnet 2: ${ipv6_subnet_2}"
            _red "The ipv6 target mask: ${target_mask}"
            exit 1
        fi

        _blue "ip tunnel add server-ipv6-${ipv6_subnets_used_num} mode ${tunnel_mode} remote ${target_address} local ${main_ipv4} ttl 255"
        _blue "ip link set server-ipv6-${ipv6_subnets_used_num} up"
        _blue "ip addr add ${ipv6_subnet_2_without_last_segment}1/${target_mask} dev server-ipv6-${ipv6_subnets_used_num}"
        _blue "ip route add ${ipv6_subnet_2_without_last_segment}/${target_mask} dev server-ipv6-${ipv6_subnets_used_num}"

        ip tunnel add server-ipv6-${ipv6_subnets_used_num} mode ${tunnel_mode} remote ${target_address} local ${main_ipv4} ttl 255
        ip link set server-ipv6-${ipv6_subnets_used_num} up
        ip addr add ${ipv6_subnet_2_without_last_segment}1/${target_mask} dev server-ipv6-${ipv6_subnets_used_num}
        ip route add ${ipv6_subnet_2_without_last_segment}/${target_mask} dev server-ipv6-${ipv6_subnets_used_num}
        update_sysctl "net.ipv6.conf.all.forwarding=1"
        sysctl_path=$(which sysctl)
        ${sysctl_path} -p
        
        # rm -rf 6in4_server.log
        # touch 6in4_server.log
        echo "# server tunnel name: server-ipv6-${ipv6_subnets_used_num}" >>6in4_server.log
        echo "# server ipv4: ${main_ipv4}" >>6in4_server.log
        echo "# client ipv4: ${target_address}" >>6in4_server.log
        echo "# ipv6 subnet: ${ipv6_subnet_2_without_last_segment}1/${target_mask}" >>6in4_server.log
        echo "ip tunnel add server-ipv6-${ipv6_subnets_used_num} mode ${tunnel_mode} remote ${target_address} local ${main_ipv4} ttl 255" >>6in4_server.log
        echo "ip link set server-ipv6-${ipv6_subnets_used_num} up" >>6in4_server.log
        echo "ip addr add ${ipv6_subnet_2_without_last_segment}1/${target_mask} dev server-ipv6-${ipv6_subnets_used_num}" >>6in4_server.log
        echo "ip route add ${ipv6_subnet_2_without_last_segment}/${target_mask} dev server-ipv6-${ipv6_subnets_used_num}" >>6in4_server.log
        echo "-----------------------------------------------------------------------------------------------" >>6in4_server.log
        update_sysctl "net.ipv6.conf.all.forwarding=1"
        update_sysctl "net.ipv6.conf.all.proxy_ndp=1"
        update_sysctl "net.ipv6.conf.default.proxy_ndp=1"
        update_sysctl "net.ipv6.conf.${interface}.proxy_ndp=1"
        update_sysctl "net.ipv6.conf.server-ipv6-${ipv6_subnets_used_num}.proxy_ndp=1"
        update_sysctl "net.ipv6.conf.all.accept_ra=2"
        $sysctl_path -p
        if [ "$system_arch" = "x86" ]; then
            wget ${cdn_success_url}https://github.com/spiritLHLS/pve/releases/download/ndpresponder_x86/ndpresponder -O /usr/local/bin/ndpresponder
            wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/extra_scripts/ndpresponder.service -O /etc/systemd/system/ndpresponder.service
            chmod 777 /usr/local/bin/ndpresponder
            chmod 777 /etc/systemd/system/ndpresponder.service
        elif [ "$system_arch" = "arch" ]; then
            wget ${cdn_success_url}https://github.com/spiritLHLS/pve/releases/download/ndpresponder_aarch64/ndpresponder -O /usr/local/bin/ndpresponder
            wget ${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/pve/main/extra_scripts/ndpresponder.service -O /etc/systemd/system/ndpresponder.service
            chmod 777 /usr/local/bin/ndpresponder
            chmod 777 /etc/systemd/system/ndpresponder.service
        fi
        if [ -f "/usr/local/bin/ndpresponder" ]; then
            new_exec_start="ExecStart=/usr/local/bin/ndpresponder -i ${interface} -n ${ipv6_address_without_last_segment}/${ipv6_prefixlen}"
            file_path="/etc/systemd/system/ndpresponder.service"
            line_number=6
            sed -i "${line_number}s|.*|${new_exec_start}|" "$file_path"
            systemctl start ndpresponder
            systemctl enable ndpresponder
            systemctl status ndpresponder 2>/dev/null
        fi
        _yellow "This tunnel will use ${tunnel_mode} type"
        _yellow "这个通道将使用${tunnel_mode}类型"
        _green "The client's host needs to have the iproute2 package installed, eg: apt install iproute2 -y"
        _green "客户端的宿主机需要安装iproute2包，比如 apt install iproute2 -y"
        _green "The following commands are to be executed on the client:"
        _green "以下是要在客户端上执行的命令:"
        _blue "ip tunnel add user-ipv6 mode ${tunnel_mode} remote ${main_ipv4} local ${target_address} ttl 255"
        _blue "ip link set user-ipv6 up"
        _blue "ip addr add ${ipv6_subnet_2_without_last_segment}2/${target_mask} dev user-ipv6"
        _blue "ip route add ::/0 dev user-ipv6"
        # rm -rf 6in4_client.log
        # touch 6in4_client.log
        echo "# server ipv4: ${main_ipv4}" >>6in4_client.log
        echo "# client ipv4: ${target_address}" >>6in4_client.log
        echo "# ipv6 subnet: ${ipv6_subnet_2_without_last_segment}2/${target_mask}" >>6in4_client.log
        echo "ip tunnel add user-ipv6 mode ${tunnel_mode} remote ${main_ipv4} local ${target_address} ttl 255" >>6in4_client.log
        echo "ip link set user-ipv6 up" >>6in4_client.log
        echo "ip addr add ${ipv6_subnet_2_without_last_segment}2/${target_mask} dev user-ipv6" >>6in4_client.log
        echo "ip route add ::/0 dev user-ipv6" >>6in4_client.log
        echo "-----------------------------------------------------------------------------------------------" >>6in4_client.log
    fi
}

# 读取参数并判断是否符合格式
target_address="${1:-None}"
tunnel_mode="${2:-sit}"
target_mask="${3:-80}"
if [ "${target_address}" == "None" ]; then
    _red "Client's IPV4 address not set"
    _red "未设置客户端的IPV4地址"
    exit 1
else
    if is_ipv4 "$target_address"; then
        _green "This target IPV4 address will be used: ${target_address}"
        _green "将使用此IPV4地址作为目标地址: ${target_address}"
    else
        _yellow "IPV4 addresses doesn't match rule"
        _yellow "IPV4地址不符合规则"
        exit 1
    fi
fi
if [[ "$tunnel_mode" == "sit" || "$tunnel_mode" == "gre" || "$tunnel_mode" == "ipip" ]]; then
    _green "Will use ${tunnel_mode} protocol for ipv6 tunnel creation"
    _green "将使用${tunnel_mode}协议进行ipv6隧道创建"
else
    _yellow "${tunnel_mode} protocol doesn't match rule"
    _yellow "${tunnel_mode} 协议不符合规则"
    exit 1
fi

if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi
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
if ! command -v sipcalc >/dev/null 2>&1; then
    _yellow "Installing sipcalc"
    ${PACKAGE_INSTALL[int]} sipcalc
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
# 防止切分的子网过小算不出来
target_mask_temp=$(calculate_subnets $ipv6_prefixlen $target_mask)
if [ "$target_mask_temp" != "$target_mask" ]; then
    target_mask=${target_mask_temp}
    _yellow "The difference between the size of the cut molecular net and the original subnet is detected to be greater than 2 to the 16th power"
    _yellow "so the size of the molecular net to be cut is modified to be /$target_mask"
    _yellow "检测到切分子网和原始子网大小差值大于2的16次方，故而修改要切分子网为 /$target_mask"
fi
# 正式映射
_green "This step will take about 1 minute, please be patient."
_green "在此步骤中将停留约 1 分钟，请耐心等待"
ipv6_tunnel
