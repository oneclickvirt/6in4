# 6in4

一键式转发迁移你的IPV6网段

One-click forwarding to migrate your IPV6 segments

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

记得跟上你的需要附加IPV6的机器的IPV4地址

## Check status

```
systemctl status ndpresponder
```

```
ip addr show
```
