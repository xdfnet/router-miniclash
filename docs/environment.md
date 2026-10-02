# 运行环境与访问方式

本项目**不部署在本机**（Mac），而是部署在一台路由器上。本文记录连接方式与运行环境，巡检 / 排障时直接照此操作，不必再问。

## 路由器

| 项 | 值 |
|---|---|
| SSH 别名 | `luyou` |
| 地址 | `192.168.100.1`（LAN `br-lan`） |
| 用户 / 端口 | `root` / `22`（Dropbear） |
| 系统 | ImmortalWrt 21.02-SNAPSHOT（OpenWrt 变种） |
| 存储 | overlayfs，可写层挂载在 `/rom/overlay` |

连接方式已写在本机 `~/.ssh/config`：

```ssh-config
Host luyou
    HostName 192.168.100.1
    User root
    IdentityFile ~/.ssh/id_ed25519_luyou
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
```

**直接执行即可，不要手动指定用户/端口/密钥：**

```bash
ssh luyou                      # 登录
ssh luyou "uptime; df -h"      # 远程执行命令
```

> 路由器 BusyBox 的 `ps` 不支持 `ps aux` 等 GNU 参数，用 `ps` 或 `ps w`。

## 网络拓扑

```
WAN ── eth1 ──▶ ImmortalWrt ── eth0/br-lan ──▶ LAN 设备
     (DHCP, 当前 192.168.1.2/24)   (192.168.100.1/24, DHCP 池 .100–.250)
```

- `eth0` 桥接为 `br-lan`，LAN 网关 `192.168.100.1/24`
- `eth1` 为 WAN，`proto dhcp`，地址会变（当前 `192.168.1.2`）
- LAN 内已知主机映射（`/etc/config/dhcp` 中的静态租约）：

| 名称 | IP | 说明 |
|---|---|---|
| Mac-Wired | 192.168.100.2 | |
| Mac-WiFi | 192.168.100.3 | |
| NanoPi-M5 | 192.168.100.5 | |
| fnos | 192.168.100.6 | 另有独立 SSH 别名 `fnos` |
| Mac | 192.168.100.10 | |
| ESP32-S3 | 192.168.100.12 | |

## 关键服务与端口

| 服务 | 端口 | 说明 |
|---|---|---|
| mihomo 混合代理 | `7893` | HTTP/HTTPS/SOCKS 混合入口 |
| mihomo 透明代理 | `7892` | iptables REDIRECT 目标（LAN 转发流量） |
| mihomo DNS | `127.0.0.1:7874` | fake-ip，dnsmasq 上游指向它 |
| mihomo API | `9090` | external-controller，secret 见 `/etc/miniclash/api_secret` |
| dnsmasq | `53` | LAN DNS/DHCP |
| uhttpd | `80` / `443` | Web 管理界面 |

## 常用巡检命令

```bash
ssh luyou "/etc/init.d/miniclash status"          # 服务状态
ssh luyou "uci get miniclash.core.node"           # 当前节点
ssh luyou "tail /etc/miniclash/judge.log"         # 裁决历史
ssh luyou "uptime; free; df -h; ps"               # 资源与进程
ssh luyou "ss -tlnp"                              # 监听端口
```

## 相关文档

- [架构说明](architecture.md)
- [mihomo 指南](mihomo-guide.md)
- [排障速查](../README.md#排障速查)
