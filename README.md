# 6in4

[![Hits](https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2Foneclickvirt%2F6in4&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false)](https://hits.seeyoufarm.com)

一键式转发迁移你的IPV6网段

One-click forwarding to migrate your IPV6 segments

自建sit/gre/ipip协议的IPv6隧道

IPv6 tunnels for self-built sit/gre/ipip protocols

该方法将提供一种方式，将A上的IPV6网段拆分一个/80的出来，附加到B上使用

This method will provide a way to split a /80 out of the IPV6 segment on A and attach it to B to use.

## Environmental Preparation

一个带有 至少/64大小的IPV6网段和一个IPV4地址的 双栈VPS (A) 和 一个只带有一个IPV4地址的VPS (B)，下面分别称为服务端和客户端，拆分后客户端将获得一个/80的IPV6子网。

A dual-stack VPS (A) with an IPV6 segment of at least /64 size and an IPV4 address and a VPS (B) with only one IPV4 address, hereafter referred to as server and client, respectively, are split so that the client will be given an IPV6 subnet of /80.

## Usage

Download Script

```
curl -L https://raw.githubusercontent.com/oneclickvirt/6in4/main/6in4.sh -o 6in4.sh && chmod +x 6in4.sh
```

Execute it

```
./6in4.sh client_ipv4 <mode_type> 
```

mode_type: sit、gre、ipip

记得写上你需要附加IPV6的机器的IPV4地址和协议类型(不填则默认为sit类型)，执行完毕后会回传你需要在客户端执行的命令，详见执行后的说明即可

Remember to write the IPV4 address and protocol type of the machine you need to attach IPV6 (not fill in the default sit type), after the execution is completed, it will send back the commands you need to be executed in the client, see the instructions after the execution.

为防止忘记复制命令，命令本身也将写入到当前路径下的 6in4.log 文件中

In case you forget to copy the command, the command itself will also be written to the 6in4.log file in the current path

## Check server status

```
systemctl status ndpresponder
```

```
ip addr show
```

## Check client status

```
ip addr show
```

```
curl ipv6.ip.sb
```

## Delete tunnel

server

```
ip link set server-ipv6 down
ip tunnel del server-ipv6
```

client

```
ip link set user down
ip tunnel del user
```

## Principle

Use 6in4's tunnel technology, along with ndpresponder to handle the NDP side of the problem, to solve the problem of forwarding IPV6 networks (/80) across different servers.

Combining https://virt.spiritlhl.net/ or https://www.spiritlhl.net/en_US/ automates the assignment of IPV6 addresses to containers.
