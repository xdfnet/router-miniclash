# Router MiniClash

**无界面**的极简全屋透明代理：mihomo 内核 + 单 init.d 脚本，1 条命令部署到 OpenWrt 路由器，接管全屋上网。无构建、无测试、无界面——验证靠真机访问与 `mihomo -t`。

- 部署目标：路由器 `192.168.100.1`（Mac 经 `ssh luyou` 访问，本机脚本均内置该别名）
- 仓库不在本机直接运行，Mac 只跑 `scripts/` 下的控制脚本
- 目录名 `router-` 前缀表示「部署在路由器」；路由器端运行时名（`/etc/config/miniclash`、`/etc/init.d/miniclash`）与此无关，照旧

## 快速上手（全新部署）

```bash
git clone https://github.com/xdfnet/router-miniclash.git && cd router-miniclash
./scripts/install.sh      # 一键部署 root/ → 路由器（缺内核/GeoIP 自动下载；不覆盖已有 UCI；末尾自动拉订阅+重启）
```

装完即启用（模板已 `enabled=1`）。日常最常用的一条：`./scripts/update-subscribe.sh` 拉订阅 → 过滤日/新节点 → 上传 → 重启。

访问方式、网络拓扑、端口详见 [docs/environment.md](docs/environment.md)。

## 配置

`/etc/config/miniclash`（uci），全部字段：

```uci
config core 'core'
  option enabled '1'         # 总开关：1 启动 / 0 停止
  option group '自动优选'     # 主代理组名（select，国家由 judge 自动裁决）
  option node '新加坡1'       # 当前实际节点（watchdog 自动更新，只读）
  option check_interval '60'  # 节点上报间隔（秒）
```

改配置 → `uci commit miniclash` → `/etc/init.d/miniclash restart`。

订阅地址**不在路由器上**，在项目根 `subscription.url`（一行）；改地址只需改这一个文件。

## 日常使用

| 想做什么 | 命令 |
|---|---|
| 启动 / 停止 / 重启 | `ssh luyou "/etc/init.d/miniclash {start\|stop\|restart}"` |
| 看当前实际节点 | `ssh luyou "uci get miniclash.core.node"` |
| 更新订阅 | `./scripts/update-subscribe.sh`（拉取→过滤日/新→上传→重启，一条龙） |
| 查套餐流量 | `./scripts/traffic.sh`（剩余 / 重置 / 到期） |
| 流量走向审计 | `./scripts/traffic-audit.sh [天数]`（代理/直连构成、兜底代理核查） |
| 巡检（一键取数） | `./scripts/inspect.sh`（9 项巡检取数，判据与汇报格式见 [docs/inspection.md](docs/inspection.md)） |
| 看裁决历史 | `ssh luyou "tail /etc/miniclash/judge.log"`（每 5 分钟一行） |
| 内核 / GeoIP 更新 | `./scripts/update-kernel.sh [--deploy]` |
| 日志智能分诊 | `./scripts/diagnose.sh`（TypeSafe Jev，需 `TYPESAFE_API_KEY` 与 jq） |
| 彻底卸载 | `./scripts/uninstall.sh` |

> **断网先查流量**：网络不通第一步 `./scripts/traffic.sh`，排除套餐耗尽再查节点/日志（2026-10-04 曾遇流量耗尽、还有 9 天才重置）。日常巡检也必看这一项。

## 自动选优

两层选优、互不干扰：
1. **组内**：mihomo 内核 `url-test` 每 60s 测 GitHub 选组内最优，单节点故障秒级自愈
2. **跨国**：`judge.sh`（cron 每 5 分钟）实测 GitHub 主站 + githubassets 双地址、延迟相加打分，连续 2 次别国领先且当前国慢 20% 才切换

一句话：**小组内快自愈，大方向按真实带宽选**。完整机制（judge 带宽判据、watchdog、启动直选）见 [docs/architecture.md](docs/architecture.md)。

## 订阅如何更新

订阅地址只在项目根 `subscription.url`。Mac 本地拉取 → base64 检测 → 过滤**强校验为 16 个日/新节点**（不符即拒绝上传） → 上传路由器 → 重启。路由器不保存订阅地址。机制细节见 [docs/architecture.md](docs/architecture.md)。

## 排障速查

| 现象 | 处理 |
|---|---|
| 海外全不通，日志 `context deadline exceeded` | iptables 本机出站被劫持成自环 → 重跑 `./scripts/install.sh` |
| 海外域名解析成假 IP、fake-ip 不生效 | dnsmasq 需 `restart`（`reload` 不重读 `/tmp/dnsmasq.d/`） |
| 重启后内核 / 订阅消失 | F2FS 吞文件 → 内核重跑 install.sh；订阅重跑 update-subscribe.sh |
| 启动失败，日志 `MMDB invalid` | GeoIP 被 F2FS 写坏 → 启动前 `mihomo -t` 已拦截并自动从备份恢复；备份也坏才重跑 install.sh |
| 某线路到个别站点不通（如日本 → gstatic） | 换**线路**（新加坡/日本），同线路换节点无效（共用一个出口） |
| 整国线路劣化（日本全 EOF / 高延迟） | judge 最多 10 分钟自动切别国；急用手动切：
`ssh luyou "curl -X PUT -H 'Authorization: Bearer \$(cat /etc/miniclash/api_secret)' -H 'Content-Type: application/json' -d '{\"name\":\"新加坡组\"}' http://127.0.0.1:9090/proxies/自动优选"` |
| judge 报「无可用国家」，过几分钟自己恢复 | BoostNet 全部节点共用**单一入口 IP**（旧台湾 HiNet），会有 5~15 分钟短窗口的全端口 TCP 阻断并自愈。**窗口 <30 分钟不必操作，>30 分钟才判真封锁**。BusyBox `nc` 探 anytls 端口会被服务端立刻关闭（假阴性），真相源用 judge 探针 + `netstat -tnp \| grep mihomo` 看 ESTABLISHED + Mac 实测。**加国家组防不住入口级阻断**，加固方向是加入口 IP / 备机场 |
| iPhone / Apple 推送不通 | 订阅 `apple.com,DIRECT` 兜成直连而本网络连不上 Apple → init.d 已自动注入 `push.apple.com → 自动优选`，重启生效 |
| Microsoft 账号 / OneDrive 登录超时 | 订阅把微软域名兜成 DIRECT → init.d 已注入 → 自动优选，重启生效 |
| 主机场流量耗尽、需临时访问国外（单设备） | 用 fnos 东方互联 `192.168.100.6:10808`（SOCKS5/HTTP）；CLI 临时 `export https_proxy=http://192.168.100.6:10808` |

## 状态

- [x] 无界面纯配置：4 个 UCI 字段 + 单 init.d + 1 条命令部署
- [x] 订阅本地更新（拉取/base64/过滤日+新 16 节点/上传/重启；路由器不保存订阅地址）
- [x] fake-ip + DNS 国内外分流，节点域名走真实 DNS 防环路
- [x] 自动选优：组内 url-test 秒级自愈 + judge 每 5 分钟双地址跨国裁决（双确认 + 20% margin 防抖）
- [x] watchdog 两层展开上报实际节点；大陆 `GEOIP,CN,DIRECT` 直连
- [x] 流量字节计量 meter.sh（按设备/域名/是否代理，保留 32 天）
- [x] 内核 + GeoIP 不入库（体积），update-kernel.sh 一条命令下载/更新；启动前 `mihomo -t` 校验、F2FS 写坏自动备份恢复
- [x] 真机验证：google / youtube / github 通，大陆直连
- [ ] UDP（TPROXY）— 暂不做

## 相关文档

- [运行环境与访问方式](docs/environment.md) — 路由器连接、网络拓扑、端口、常用巡检命令
- [架构说明](docs/architecture.md) — 目录结构、运行时文件、调用链路、自动选优与订阅注入机制（实现细节都在这里）
- [组内选优](docs/group-selection.md) — 国家 url-test 组怎么选节点、tolerance 取值依据、按带宽择优的坑
- [跨国选优](docs/country-selection.md) — 国家之间怎么切：带宽判据、测速方法、防抖、流量预算
- [mihomo 指南](docs/mihomo-guide.md) — 内核各能力的使用与设计取舍（fake-ip、透明代理、DNS 分流、TLS 指纹）
- [事故报告：2026-09-01 拨号失败](docs/incident-2026-09-01-boostnet-dial-failure.md) — TLS 指纹超 MSS + GSO 丢段根因