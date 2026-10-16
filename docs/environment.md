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

## DNS 走向

| 状态 | 上游 | 说明 |
|---|---|---|
| 代理开启 | mihomo `127.0.0.1:7874` | dnsmasq 的 `/tmp/dnsmasq.d/miniclash.conf`（`no-resolv` + `server=127.0.0.1#7874`）接管；全屋（含路由器本机）走 mihomo 分流：海外域名经代理解析、国内域名走国内 DoH |
| 代理关闭 | `223.5.5.5` / `119.29.29.29` | `miniclash stop` 删掉上述 conf，dnsmasq 回落 `resolv-file`（`/tmp/resolv.conf.d/resolv.conf.auto`）= 阿里 + 腾讯 |

- WAN 口 `eth1` 已设 `peerdns=0` + 固定 DNS（`uci add_list network.wan.dns`），**不再用光猫/运营商 DNS**（原为光猫下发的 `192.168.1.1`）。2026-10-14 tcpdump 实证：关闭代理时 DNS 包全部发往 `223.5.5.5`，零发往 `192.168.1.1`。
- 改法：`uci set network.wan.peerdns=0; uci add_list network.wan.dns=223.5.5.5; uci add_list network.wan.dns=119.29.29.29; uci commit network; ifup wan`

> **路由器本机解析的坑**：路由器自身（非转发流量）不走 iptables 劫持。代理开启时本机解析拿到 fake-ip（`198.18.x.x`），却无法直连该假 IP —— 故路由器自身主动访问域名（如 `opkg update`、本机 `curl`）会失败，属设计使然；LAN 设备不受影响。

## 关键服务与端口

| 服务 | 端口 | 说明 |
|---|---|---|
| mihomo 混合代理 | `7893` | HTTP/HTTPS/SOCKS 混合入口 |
| mihomo 透明代理 | `7892` | iptables REDIRECT 目标（LAN 转发流量） |
| mihomo DNS | `127.0.0.1:7874` | fake-ip，dnsmasq 上游指向它 |
| mihomo API | `9090` | external-controller，secret 见 `/etc/miniclash/api_secret` |
| dnsmasq | `53` | LAN DNS/DHCP |
| uhttpd | `80` / `443` | Web 管理界面 |

## fnos 备用代理（dfhl / 东方互联）

主机场侧故障时的**单设备兜底**，跑在 fnos 的 Docker 里，与路由器完全独立。

**形态**：官方镜像（非自建）。容器内 `/opt/dfhl/dfhld` 是守护进程，拉起子进程 `/opt/dfhl/sing-box` 做代理内核；配置由 dfhld 运行时生成、不落盘（`/data/state/` 下只有 `cache.db` 与日志）。

| 项 | 值 |
|---|---|
| SSH 别名 | `fnos`（`192.168.100.6`，Debian 12 x86_64） |
| 入口 | `192.168.100.6:10808`（HTTP/SOCKS 混合） |
| 容器 | `dfhl`（`dfhl:latest`，`network_mode: host`，`cap_drop: ALL`） |
| compose | `/vol1/docker/dfhl/docker-compose.yml` |
| 数据卷 | `/vol1/docker/dfhl/data` → 容器 `/data`（`config/`、`state/`） |
| 自启 | `restart: unless-stopped`（由 docker 守护进程拉起） |
| 官方镜像包 | `/vol1/dfhl-docker-amd64.tar.gz` |

**用法**（单设备临时走国外）：

```bash
export https_proxy=http://192.168.100.6:10808
```

**部署 / 升级**（官方给 tar 包，load 后重建容器即可；`data/` 在卷上，配置与凭据不会丢）：

```bash
docker load -i /vol1/dfhl-docker-amd64.tar.gz
cd /vol1/docker/dfhl && docker compose up -d
```

> **前提：fnos 出网必须绕过 mihomo。** 否则它连上游的流量会被 MINICLASH 链劫持、绕走主代理——主代理一挂，兜底跟着失效，恰在最需要它时不可用（2026-10-16 实证）。放行规则见 [architecture.md](architecture.md) 的「透明代理（iptables）」一节，由 init.d 生成。
>
> 账号密码明文存在 compose 的 `environment:`（文件权限 644）。要收紧可改用 `env_file` 并设 600。

**DNS 必须独立（2026-10-16 配死）**：fnos 若用路由器当 DNS，mihomo 会对**所有**域名（含国内）回 fake-ip；而 fnos 已被放行、不经过 mihomo，**没人把假 IP 还原成域名** → 解析全废、dfhld 登录超时。已改为走公网 DNS，写入 NetworkManager：

```ini
[ipv4]
dns=223.5.5.5;119.29.29.29;
ignore-auto-dns=true
```

改法（root 权限受限时经 docker 提权，admin 在 docker 组）：挂载 `/etc/NetworkManager/system-connections` 改 `Wired connection 1.nmconnection`，再 `nsenter -t 1 -m -p -u -i -n systemctl restart NetworkManager`。备份 `/vol1/nm-backup-20261016.nmconnection`。

**节点要显式指定**：compose 的 `command` 加 `--node 日本`。不指定时 dfhld 用订阅里第一个可用节点，2026-10-16 那次它挑中的新加坡节点已失效，导致全程连不上（备份同名 `.bak-20261016`）。

**排查命令**（容器内，无需密码）：

```bash
docker exec dfhl /opt/dfhl/dfhld nodes     # 列 6 个节点（新/俄/日/澳/美/阿联酋）
docker exec dfhl /opt/dfhl/dfhld status    # 当前节点、sing-box PID
docker exec dfhl /opt/dfhl/dfhld logs -n 50
```

容器内另有 clash-api（`127.0.0.1:9090`）可查节点与策略组。容器 resolv.conf 是**启动时生成**的，改完宿主 DNS 必须**重建容器**（`docker compose up -d`）才会继承。

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
