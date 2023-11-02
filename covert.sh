#!/bin/bash
# from
# https://github.com/oneclickvirt/6in4
# 2023.11.02

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

# 检测 ifupdwon/ifupdown2/无 属于那种情况
# 检测 ifupdown2
status_ifupdown=-1
if [ "$SYSTEM" = "Debian" ] || [ "$SYSTEM" = "Ubuntu" ]; then
    if dpkg -S ifupdown2 &>/dev/null; then
        status_ifupdown=2
    else
        # 检测 ifupdown
        if dpkg -s ifupdown &>/dev/null; then
            status_ifupdown=1
        else
            status_ifupdown=0
        fi
    fi
else
    _red "Not Debin or Ubuntu systems cannot be converted automatically."
fi

chattr -i /etc/network/interfaces
if [ "$status_ifupdown" == 1 ]; then
    # 对于 ifupdown 非 ifupdown2 的情况，转换为 v4tunnel 类型
    sed -i '/^mode sit/d' /etc/network/interfaces
    sed -i 's/tunnel/v4tunnel/g' /etc/network/interfaces
elif [ "$status_ifupdown" == 2 ]; then
    # 对于 ifupdown2 非 ifupdown 的情况，转换为 sit 类型
    sed -i 's/v4tunnel/tunnel/g' /etc/network/interfaces
    sed -i '/tunnel/ a\    mode sit' /etc/network/interfaces
elif [ "$status_ifupdown" == 0 ]; then
    # 对于都没有的情况，尝试安装 ifupdown 并转换为 v4tunnel 类型，不行再换另一种形式
    apt-get install ifupdown -y
    if [[ $? -eq 0 ]]; then
        sed -i '/^mode sit/d' /etc/network/interfaces
        sed -i 's/tunnel/v4tunnel/g' /etc/network/interfaces
    else
        apt-get install ifupdown2 -y
        if [[ $? -eq 0 ]]; then
            sed -i 's/v4tunnel/tunnel/g' /etc/network/interfaces
            sed -i '/tunnel/ a\    mode sit' /etc/network/interfaces
        fi
    fi
fi

# 检测是否存在路由冲突的情况，如果存在则删除默认的IPV6路由，如果不存在则不做处理
