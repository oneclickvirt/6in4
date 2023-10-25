# 6in4

[![Hits](https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2Foneclickvirt%2F6in4&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false)](https://hits.seeyoufarm.com)

一键式转发迁移你的IPV6网段

[English](README.md) | [中文文档](README_zh.md)

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
| 以下称之为服务端 | 以下称之为服务端客户端 |

## 使用方法

下载脚本

```
curl -L https://raw.githubusercontent.com/oneclickvirt/6in4/main/6in4.sh -o 6in4.sh && chmod +x 6in4.sh
```

执行命令

```
./6in4.sh client_ipv4 <mode_type> <subnet_size> 
```

| 选项 | 可选的选项1 | 可选的选项2 | 可选的选项3 |
|--------|--------|--------|--------|
| <mode_type> | gre | sit | ipip |
| <subnet_size> | 64 | 80 | 112 |

```<mode_type>```暂时只支持那三种协议，越靠前的越推荐，不填则默认为```sit```协议

```<subnet_size>```只要比原系统子网掩码大就行，且是2的倍数，不填则默认为```80```

记得```client_ipv4```替换为需要附加IPV6的机器的IPV4地址，执行完毕后会回传你需要在客户端执行的命令，详见执行后的说明即可

为防止忘记复制命令，命令本身也将写入到当前路径下的```6in4.log```文件中，可使用```cat 6in4.log```查询客户端需要执行的命令

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

```
ip link set server-ipv6 down
ip tunnel del server-ipv6
```

客户端

```
ip link set user-ipv6 down
ip tunnel del user-ipv6
```
