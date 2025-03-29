# 6in4

[![Hits](https://hits.spiritlhl.net/6in4.svg?action=hit&title=Hits&title_bg=%23555555&count_bg=%230eecf8&edge_flat=false)](https://hits.spiritlhl.net)

一键式转发迁移你的IPV6网段

[English](README.md) | [中文文档](README_zh.md)

类似 https://tunnelbroker.net/ 自建一个 "Hurricane Electric Free IPv6 Tunnel Broker"

## 功能

- [x] 自建sit/gre/ipip协议的IPv6隧道
- [x] 支持自定义要切分出来的IPV6子网大小，将自动计算出合适的CIDR格式的IPV6子网信息
- [x] 自动识别服务端的IPV6子网大小
- [x] 将自动设置隧道服务端并打印客户端需要执行的命令
- [x] 设置IPV6隧道的方法简单易懂，易于删除

## 环境准备

| VPS(A) | VPS(B) |
|--------|--------|
| 一个IPV4地址(server_ipv4) | 一个IPV4地址(clinet_ipv4) |
| 一个IPV6子网 | 无IPV6地址 |
| 以下称之为服务端 | 以下称之为客户端 |

## 使用方法

下载脚本

```
curl -L https://raw.githubusercontent.com/oneclickvirt/6in4/main/6in4.sh -o 6in4.sh && chmod +x 6in4.sh
```

执行命令

```
./6in4.sh <client_ipv4> <mode_type> <subnet_size> 
```

可重复执行，切分多个子网，对应不同的客户端(服务器)，```client_ipv4```为必填项，其他为可选项

记得```client_ipv4```替换为需要附加IPV6的机器的IPV4地址，执行完毕后会回传你需要在客户端执行的命令，详见执行后的说明即可

| 选项 | 可选的选项1 | 可选的选项2 | 可选的选项3 |
|--------|--------|--------|--------|
| <mode_type> | gre | sit | ipip |

| 选项 | 可选的选项1 | 可选的选项2 | 可选的选项3 |
|--------|--------|--------|--------|
| <subnet_size> | 64 | 80 | 112 |

```<mode_type>```暂时只支持那三种协议，越靠前的越推荐，不填则默认为```sit```协议

```<subnet_size>```只要比原系统子网掩码大就行，且是8的倍数，若切分子网和原始子网大小差值大于2的16次方，会自动调整，不填则默认为```80```

脚本执行过程中，执行路径将自动切换至于```/root```下

为防止忘记复制命令，客户端要执行的命令本身也将写入到当前路径下的```6in4_client.log```文件中，可使用```cat 6in4_client.log```查询客户端需要执行的命令

为防止忘记重启后服务器隧道消失，服务端要执行的命令本身也将写入到当前路径下的```6in4_server.log```文件中，可使用```cat 6in4_server.log```查询服务端重启后重新部署隧道需要执行的命令

## 注意

### 隧道路由与默认路由冲突

由于部分服务器存在默认的内网IPV6路由会与隧道冲突，此时可使用以下命令删除默认的IPV6路由。(以下命令仅限于你附加时出现报错且附加失败时才执行，否则不要轻易执行以下命令。)

```
default_route=$(ip -6 route show | awk '/default via/{print $3}') && [ -n "$default_route" ] && ip -6 route del default via $default_route dev eth0
```

这里假设了你的客户端的服务器的默认网卡是```eth0```，你可以使用```ip -6 route```查看默认的路由并替换它，默认路由以```default via```开头，使用```dev```指定默认网卡，你只需要按照这个规则找到它即可

### 宿主机多网络接口

脚本默认不兼容多网络接口的情况，遇到执行日志出现```ipv6_gateway:```后识无输出的情况，你需要执行```ip -6 route show```查看ipv6的gateway地址后自行写入到文件```/usr/local/bin/6in4_ipv6_gateway```中，然后再次执行脚本即可。

一个实际的例子：https://github.com/oneclickvirt/6in4/issues/2

## 检测服务端

```
systemctl status ndpresponder
```

```
ip addr show
```

## 检测客户端

```
ip addr show
```

```
curl ipv6.ip.sb
```

## 删除隧道

服务端

执行

```
cat /root/6in4_server.log
```

可查看使用的隧道名字，以```server-ipv6-```开头

```
ip link set <name> down
ip tunnel del <name>
```

将上面的```<name>```改为查询到的名字即可

客户端

```
ip link set user-ipv6 down
ip tunnel del user-ipv6
```

## 持久化隧道

详见 [https://virt.spiritlhl.net/guide/incus_custom.html](https://virt.spiritlhl.net/guide/incus_custom.html) 和 [https://ipv6tunnel.spiritlhl.top/](https://ipv6tunnel.spiritlhl.top/) 中的说明
