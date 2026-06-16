# 6in4

[![Hits](https://hits.spiritlhl.net/6in4.svg?action=hit&title=Hits&title_bg=%23555555&count_bg=%230eecf8&edge_flat=false)](https://hits.spiritlhl.net)

一键创建 IPv6-over-IPv4 隧道，将服务端已有的公网 IPv6 前缀分配给另一台主机使用。

[English](README.md) | [中文文档](README_zh.md)

类似自建一个轻量版的 "Hurricane Electric Free IPv6 Tunnel Broker"。

## 功能

- [x] Linux 服务端支持 `sit`、`gre`、`ipip` 隧道
- [x] BSD 通过 `sit` 模式使用 `gif(4)` 实现 IPv6-over-IPv4
- [x] 严格校验 IPv4 和 IPv6 地址
- [x] 自动检测公网网卡和网关，并过滤虚拟/VPN/隧道接口
- [x] 持久化记录 IPv6 子网分配，删除隧道后可回收子网
- [x] 运行状态存储在 `/var/lib/6in4`，日志存储在 `/var/log/6in4`
- [x] 使用 `flock` 或目录锁防止并发执行
- [x] 根据底层网卡 MTU 自动计算隧道 MTU 和 TCP MSS
- [x] 创建后执行隧道诊断和可选 ping6 健康检查
- [x] 支持的 Linux 架构上下载 ndpresponder 时进行 SHA256 校验
- [x] 生成 systemd、netplan、systemd-networkd、ifcfg 和 BSD 持久化模板
- [x] 可通过参数或环境变量关闭 telemetry

## 环境准备

| 服务端 | 客户端 |
| --- | --- |
| 一个公网 IPv4 地址 | 一个公网 IPv4 地址 |
| 一个公网可路由 IPv6 前缀 | 不需要原生 IPv6 |
| Linux 或 BSD root shell | 生成的客户端命令面向 Linux root shell |

脚本会在可能时通过系统包管理器安装缺失依赖。支持的包管理器包括 `apt`、`apk`、`pacman`、`dnf`、`yum`、`zypper`、FreeBSD `pkg` 和 OpenBSD `pkg_add`。

## 使用方法

下载脚本：

```bash
curl -L https://raw.githubusercontent.com/oneclickvirt/6in4/main/6in4.sh -o 6in4.sh
chmod +x 6in4.sh
```

在拥有 IPv6 前缀的服务端执行：

```bash
./6in4.sh <client_ipv4> [mode_type] [subnet_size]
```

示例：

```bash
./6in4.sh 203.0.113.10 sit 80
./6in4.sh 203.0.113.10 gre 64 --no-telemetry
./6in4.sh 203.0.113.10 sit 80 --interface eth0 --skip-health-check
```

参数：

| 参数 | 说明 |
| --- | --- |
| `mode_type` | Linux 支持 `gre`、`sit`、`ipip`。BSD 使用 `sit`，底层由 `gif(4)` 实现。默认：`sit`。 |
| `subnet_size` | IPv6 子网前缀长度，如 `64`、`80`、`112`。必须大于或等于服务端前缀，且为 8 的倍数。默认：`80`。 |
| `--interface <name>` | 指定服务端公网网卡。 |
| `--no-telemetry` | 关闭 hits 统计请求。 |
| `--skip-health-check` | 跳过创建后的 ping6 健康检查。 |
| `--no-persist` | 生成持久化文件，但不自动启用 systemd 服务。 |
| `--skip-ndpresponder` | 跳过 ndpresponder 安装和启动。仅在你已用其他方式处理 NDP/代理时使用。 |
| `--dry-run` | 不执行 root 网络修改，仅跑通分配、日志和持久化模板流程。 |

环境变量：

| 变量 | 说明 |
| --- | --- |
| `SIXIN4_STATE_DIR` | 运行状态目录。默认：`/var/lib/6in4`。 |
| `SIXIN4_LOG_DIR` | 日志目录。默认：`/var/log/6in4`。 |
| `SIXIN4_NO_TELEMETRY=1` | 等同于 `--no-telemetry`。 |
| `SIXIN4_INTERFACE=<name>` | 等同于 `--interface <name>`。 |
| `SIXIN4_DRY_RUN=1` | 等同于 `--dry-run`。 |
| `CN=true` | 自动优先选择可用的 GitHub CDN。 |

旧版 `6IN4_*` 名称仍可通过 `env` 传入，例如 `env 6IN4_STATE_DIR=/tmp/6in4 ./6in4.sh ...`。建议使用 `SIXIN4_*` 别名，因为它们可以直接用于 POSIX 风格 shell 变量赋值。

dry-run 测试变量：

```bash
SIXIN4_OS_FAMILY=linux
SIXIN4_INTERFACE=eth0
SIXIN4_MAIN_IPV4=198.51.100.2
SIXIN4_IPV4_CIDR=198.51.100.2/24
SIXIN4_IPV4_GATEWAY=198.51.100.1
SIXIN4_IPV6_CIDR=2001:470:64::1/64
SIXIN4_IPV6_GATEWAY=fe80::1
SIXIN4_UNDERLAY_MTU=1500
```

## 状态和日志

运行状态不再写入 `/usr/local/bin`：

```text
/var/lib/6in4/allocations.tsv
/var/lib/6in4/subnets_*.list
/var/lib/6in4/persistent/<tunnel_name>/
/var/log/6in4/6in4_server.log
/var/log/6in4/6in4_client.log
```

日志默认超过 1 MiB 自动轮转。可通过 `SIXIN4_LOG_MAX_BYTES` 和 `SIXIN4_LOG_KEEP` 调整。

## 客户端配置

服务端隧道创建后，脚本会打印客户端命令，并写入 `/var/log/6in4/6in4_client.log`。客户端持久化模板会生成在：

```text
/var/lib/6in4/persistent/<tunnel_name>/
```

本项目不会生成密码或私钥。

## 删除隧道

在服务端下载并执行清理脚本：

```bash
curl -L https://raw.githubusercontent.com/oneclickvirt/6in4/main/6in4-delete.sh -o 6in4-delete.sh
chmod +x 6in4-delete.sh
./6in4-delete.sh --list
./6in4-delete.sh <tunnel_name>
```

删除所有活动记录：

```bash
./6in4-delete.sh --all
```

删除操作会移除内核隧道、停用已生成的 systemd 服务，并将分配记录标记为 deleted，使子网可被后续运行回收。

非破坏性状态流检查：

```bash
SIXIN4_STATE_DIR=/tmp/6in4-dry-run/state ./6in4-delete.sh --dry-run --all
```

`--dry-run` 只预览删除操作，不会删除持久化文件，也不会修改 `allocations.tsv`。

客户端删除：

```bash
ip link set user-ipv6 down
ip tunnel del user-ipv6
```

## 持久化

Linux 会生成：

- `server-up.sh` 和 `server-down.sh`
- `6in4-<tunnel_name>.service`
- `systemd-networkd-<tunnel_name>.netdev`
- `systemd-networkd-<tunnel_name>.network`
- `netplan-<tunnel_name>.yaml`
- `ifcfg-<tunnel_name>`
- 客户端 shell、systemd 和 `client-install.sh` 模板

当系统存在 systemd 且未使用 `--no-persist` 时，服务端 systemd 单元会自动启用，以便重启后恢复隧道。netplan、systemd-networkd、ifcfg 和 BSD 文件仅生成模板，因为盲目安装可能与现有网络管理器冲突。

## 诊断

检查服务端：

```bash
ip addr show
ip -6 route show
systemctl status ndpresponder
```

检查客户端：

```bash
ip addr show
curl ipv6.ip.sb
```

健康检查会在服务端创建后 ping 生成的客户端 IPv6 地址。客户端尚未应用隧道配置前该检查可能失败，脚本会输出隧道、地址和路由诊断信息。

## ifupdown 转换辅助脚本

`covert.sh` 用于在 `ifupdown` 和 `ifupdown2` 之间转换 `/etc/network/interfaces` 的隧道语法。现在会先备份文件，转换后使用 `ifquery --check --all` 或 `ifup --no-act -a` 验证配置；如果验证或重启 networking 失败，会自动恢复备份。
