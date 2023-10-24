# 6in4

[![Hits](https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2Foneclickvirt%2F6in4&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false)](https://hits.seeyoufarm.com)

一键式转发迁移你的IPV6网段

One-click forwarding to migrate your IPV6 segments

自建sit协议的IPv6隧道

IPv6 tunnels for self-built sit protocols

## Environmental Preparation

一个带有至少/64子网大小的 双栈VPS (A) 和 一个只有一个IPV4地址的VPS (B)，下面分别称为服务端和客户端。

A dual-stack VPS (A) with at least /64 subnet size and a VPS (B) with only one IPV4 address, hereafter referred to as server and client, respectively.

## Usage

Download Script

```
curl -L https://raw.githubusercontent.com/oneclickvirt/6in4/main/6in4.sh -o 6in4.sh && chmod +x 6in4.sh
```

Execute it

```
./6in4.sh your_client_ipv4
```

记得写上你需要附加IPV6的机器的IPV4地址

Remember to write the IPV4 address of the VPS(B) to which you need to attach IPV6

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

## Principle

Use 6in4's tunnel technology, along with ndpresponder to handle the NDP side of the problem, to solve the problem of forwarding IPV6 networks across different servers.

Combining https://virt.spiritlhl.net/ or https://www.spiritlhl.net/en_US/ automates the assignment of IPV6 addresses to containers.
