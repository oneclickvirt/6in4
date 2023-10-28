# 6in4

[![Hits](https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2Foneclickvirt%2F6in4&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false)](https://hits.seeyoufarm.com)

One-click forwarding to migrate your IPV6 segments

[English](README.md) | [中文文档](README_zh.md)

Similar to https://tunnelbroker.net/ Build your own "Hurricane Electric Free IPv6 Tunnel Broker"

## Features

- [x] Self-built IPv6 tunnel for sit/gre/ipip protocols
- [x] Support to customize the IPV6 subnet size to be cut out, and the appropriate IPV6 subnet information in CIDR format will be calculated automatically.
- [x] Automatically recognizes the IPV6 subnet size of the server side
- [x] will automatically set up the tunnel server and print the commands that the client needs to execute
- [x] Setting up the IPV6 tunnel is easy to understand and easy to remove

## Environmental Preparation

| VPS(A) | VPS(B) |
| --------|--------|
| one IPV4 address (server_ipv4) | one IPV4 address (clinet_ipv4) |
| one IPV6 subnet | no IPV6 address |
| Hereafter referred to as server | Hereafter referred to as client |

## Usage

Download Script

```
curl -L https://raw.githubusercontent.com/oneclickvirt/6in4/main/6in4.sh -o 6in4.sh && chmod +x 6in4.sh
```

Execute it

```
./6in4.sh client_ipv4 <mode_type> <subnet_size> 
```

| Options | Optional Option 1 | Optional Option 2 | Optional Option 3 |
|--------|--------|--------|--------|
| <mode_type> | gre | sit | ipip |
| <subnet_size> | 64 | 80 | 112 |

```<mode_type>``` only support those three protocols for now, the more advanced the more recommended, no fill in the default is ```sit``` protocol

```<subnet_size>``` as long as it is larger than the original system subnet mask, and is a multiple of 8, if you don't fill it in, it defaults to ```80```.

Remember to replace ```client_ipv4``` with the IPV4 address of the machine you want to attach IPV6 to, and the command you need to execute on the client side will be sent back to you after execution, see the instructions after execution for details.

To prevent forgetting to copy commands, the commands to be executed by the client itself will be written to the ```6in4.log``` file under the current path, and the commands to be executed by the client can be queried using ```cat 6in4.log```.

To prevent forgetting that the server tunnel disappears after reboot, the commands to be executed by the server itself will be written to the ```6in4_server.log``` file under the current path, you can use ```cat 6in4_server.log``` to query the commands that need to be executed by the server to redeploy the tunnel after reboot.

Because some servers have default intranet IPV6 routes that conflict with the tunnel, you can use the following command to remove the default IPV6 routes

```
default_route=$(ip -6 route show | awk '/default via/{print $3}') && [ -n "$default_route" ] && ip -6 route del default via $default_route dev eth0
```

This assumes that your client's server's default NIC is ```eth0```, and you can use ```ip -6 route``` to see the default route and replace it, the default route starts with ``default via`` and uses ``dev`` to specify the default NIC, you just need to find it by following this rule.

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
ip link set user-ipv6 down
ip tunnel del user-ipv6
```

## Persistent tunnel

See [https://www.spiritlhl.net/en_US/guide/lxd_custom.html#usage](https://www.spiritlhl.net/en_US/guide/lxd_custom.html#usage) for more details