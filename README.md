# MiniClash

**无界面**的极简全屋透明代理。1 个配置文件 + 1 个 init.d 脚本 + 1 条安装命令，让 mihomo 内核接管全屋上网。

## 为什么做

代理需求其实很简单：订阅 + 内核 + 透明代理 + 节点切换。
链路越复杂，出问题越难排查。MiniClash 只留核心链路，代码量小一个数量级，出问题一眼能查。

## 配置（一切都在这里）

`/etc/config/miniclash`，配置都在这里：

```uci
config core 'core'
    option enabled '1'                  # 总开关：1 启动，0 停止
    option group '自动优选'             # 主代理组名（select，国家由 judge 裁决）
    option node '新加坡1'               # 当前实际节点（watchdog 自动更新，仅供查看）
    option check_interval '60'          # 节点上报间隔（秒）
```

改配置 → `uci commit miniclash` → `/etc/init.d/miniclash restart`。

**订阅更新在本地**：路由器不保存订阅地址，由 Mac 脚本拉取、过滤后上传（见下）。

## 部署

```bash
./scripts/install.sh        # 一键安装到路由器（缺内核/GeoIP 时自动下载，不覆盖已有配置）
./scripts/update-kernel.sh  # 下载/更新 mihomo 内核 + GeoIP 库（加 --deploy 同步并重启）
./scripts/uninstall.sh      # 彻底卸载
./scripts/update-subscribe.sh # 本地拉订阅过滤日/新节点后上传（install 自动执行一次）
./scripts/traffic.sh        # 查看套餐剩余流量 / 重置 / 到期
```

订阅地址在项目根 `subscription.url`（一行），改地址只需改这一个文件。首次安装后直接启用（模板已 `enabled=1`）：

```bash
/etc/init.d/miniclash enable
/etc/init.d/miniclash start
```

### 内核与 GeoIP 库（来源 / 放置位置）

内核 `/usr/bin/mihomo`（~55M）与 GeoIP 库 `Country.mmdb`（~8M）**不入库**（见 `.gitignore`），新克隆的仓库里没有这两个文件。用 `update-kernel.sh` 下载，脚本按下面两处路径放置；`install.sh` 发现缺失会自动先调它补齐。

| 文件 | 下载来源 | 项目内放置位置（本地） | 路由器部署位置 |
|---|---|---|---|
| 内核 | `https://github.com/MetaCubeX/mihomo/releases/download/<ver>/mihomo-<platform>-<ver>.gz`<br>版本号取自 `https://api.github.com/repos/MetaCubeX/mihomo/releases/latest` | `root/usr/bin/mihomo` | `/usr/bin/mihomo` |
| GeoIP 库 | `https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb`（常青 latest） | `root/etc/miniclash/Country.mmdb` | `/etc/miniclash/Country.mmdb`<br>（另备份 `/usr/share/miniclash/etc/miniclash/Country.mmdb`） |

```bash
./scripts/update-kernel.sh            # 下载/更新到项目 root/ 下
./scripts/update-kernel.sh --deploy   # 下载后同步到路由器并重启服务
```

- `MICLASH` 默认平台 linux-arm64（mt7981 路由器），可用 `PLATFORM=xxx` 覆盖（如 `PLATFORM=linux-amd64`）。
- 版本相同则跳过内核；GeoIP 库每次拉最新。
- 手动放置也行：把内核放到 `root/usr/bin/mihomo`、GeoIP 放到 `root/etc/miniclash/Country.mmdb`，再跑 `install.sh` 同步即可。

## 日常使用

- 启动 / 停止 / 重启：`/etc/init.d/miniclash {start|stop|restart}`
- 看状态：`/etc/init.d/miniclash status`
- 看当前节点：`uci get miniclash.core.node`（watchdog 每周期自动更新）
- 更新订阅：`./scripts/update-subscribe.sh`（本地拉取 → 过滤日本/新加坡节点 → 上传 → 重启，一条龙）
- 查套餐：`./scripts/traffic.sh`（剩余流量 / 下次重置 / 套餐到期 / 官网，信息条目藏在订阅里）
- 看裁决历史：`ssh luyou "tail /etc/miniclash/judge.log"`（独立日志，每 5 分钟一行：各国分数 + 保持/候选/切换；保留约 8.7 天，不被内核 warning 淹没）
- 日志智能分诊：`./scripts/diagnose.sh`（TypeSafe Jev 判断节点故障 / 故障类型 / 健康度，需 `TYPESAFE_API_KEY` 与 jq；日志自动脱敏后出网）
- 自动选优：主组「自动优选」是 select 组，成员为新加坡组/日本组两个 url-test 国家组——组内单节点故障内核秒级自愈；整国劣化时 judge.sh 每 5 分钟对 GitHub 主站 + githubassets(Fastly) 两个地址计时相加、谁总分短选谁，连续 2 次领先 20% 才自动跨国切换，防打地鼠。`node` 由 watchdog 两层展开上报

## 节点怎么自动切换（两层，互不干扰）

```
自动优选 (select)            ◀ 第二层：judge 决定走哪个国家
├── 日本组 (url-test)       ◀ 第一层：内核 60s 在组内自动选节点（启动默认）
│   └── 日本1 … 8
├── 新加坡组 (url-test)
│   └── 新加坡1 … 8
└── 日本组 (url-test)
    └── 日本1 … 8
```

| | 第一层：组内选节点 | 第二层：跨国别选择 |
|---|---|---|
| 谁做 | mihomo 内核 `url-test` | `judge.sh`（cron） |
| 频率 | 每 **60 秒** | 每 **5 分钟** |
| 怎么判 | 测 GitHub，选延迟最低 | GitHub主站+githubassets 两地址计时相加 |
| 防抖 | 领先 500ms 才切 | 连续 **2 次**领先 **且**当前国慢 **20%** 才切 |
| 应对 | 单节点挂了 → 秒级自愈 | 整国劣化 → 换国家逃生 |

> 一句话：**小组内快自愈，大方向稳不抖**。judge 不是每轮都切——条件不满足只记一行「保持」。

> **开机 / 重启**时内核会立刻前台测一次（BOOT 模式），十几秒内直选当前最优国家，不用干等 5 分钟 cron。

## 怎么工作

```
LAN 设备 ──▶ dnsmasq ──▶ mihomo fake-ip (7874)     真实 DNS (DoH)
    │            ▲                                    │
    │ TCP        └── 域名解析 ── 防污染 ──────────────┘
    ▼
iptables REDIRECT (7892) ──▶ mihomo ── anytls ──▶ 节点 ──▶ 海外
                                   │
                              GEOIP,CN → DIRECT（大陆直连）
```

LAN 设备的 TCP 被 iptables 重定向进内核，域名解析被 dnsmasq 交给内核的 fake-ip DNS；内核按订阅规则分流，海外走节点、大陆直连。下面讲清每个内核功能是怎么用、为什么这么用。

## 内核功能怎么用

MiniClash 直接用 mihomo 内核的能力，不重复造轮子：

**① 透明代理**（`redir-port: 7892`）
iptables 把 LAN 的 TCP 全量 REDIRECT 到 7892，内核从 socket 取回原目标地址（SO_ORIGINAL_DST）再按规则分流。只劫持 LAN 转发流量（PREROUTING），**本机出站不劫持**——否则内核连节点的连接会被重定向回自己，形成自环。

**② fake-ip DNS**（`listen: 127.0.0.1:7874` + `enhanced-mode: fake-ip`）
dnsmasq 上游指向 7874（配置后需 `restart` 才生效）。内核把域名映射成 `198.18.0.1/16` 的假 IP 返回；客户端连接假 IP 时，内核还原出真实域名再匹配规则、走节点。域名层面的分流、防泄漏、防污染都由它完成，客户端根本碰不到真实 IP。

**③ DNS 三层防污染**
- `nameserver`：国内 DoH（`https://doh.pub/dns-query`、`https://dns.alidns.com/dns-query`），主解析，不污染海外域名
- `fallback`：明文 DNS（223.5.5.5 / 119.29.29.29）兜底
- `proxy-server-nameserver`：节点域名（如 `节点.example.com`）用真实 DNS 解析，防止被 fake-ip 化导致内核连节点死循环
- `default-nameserver`：bootstrap，解析 DNS 服务器自身的域名

**④ 跨国自动选优**（`external-controller: 9090` + `secret`）
主组「自动优选」是 **select** 组，成员为每国一个 **url-test** 组（新加坡组/日本组，每 60s 测 GitHub 选组内最优，tolerance 500ms 防抖）——单节点故障组内秒级自愈。国家级劣化由 `/usr/share/miniclash/judge.sh`（cron 每 5 分钟）裁决：对每节点实测两个真实地址 `github.com/generate_204` + `github.githubassets.com/generate_204`（后者是 GitHub 网页静态资源走的 Fastly 链路，返回 404 但握手成功、照样计时），**节点分 = 两地址延迟相加**，国家分 = 最快 2 个活节点的节点分均值；连续 2 次同一别国领先且当前国慢 20%（当前国不可用直接满足）才经 API `PUT` 切换 select——双确认 + margin 防横跳。watchdog 只做两层展开（select → 国家组 → 节点）把实际节点落盘 `node`，不驱动切换。

**⑤ 订阅本地过滤 + YAML 直通**
订阅地址存在于项目根 `subscription.url`：Mac 本地拉取（base64 自动解码）后过滤 `proxies:` 段，仅保留日本/新加坡 16 个节点（信息伪装条目同步剔除），订阅自带 proxy-groups 段整段删除，再上传路由器。rules（含 `GEOIP,CN,DIRECT` 大陆直连）原样保留，节点与规则由内核原生解析，不翻译任何协议；MiniClash 只覆盖端口 / DNS / API 三块头部。所有规则走「自动优选」。

五处例外：
- **自动优选组**：init.d 按节点名前缀归集到国家组，在 rules 段前生成 select 主组 + 每国一个 url-test 组（`interval: 60 / tolerance: 500 / expected-status: 200/204`，expected-status 只认真实 204 防劫持假 200 误判），并把 rules 里所有 `,BoostNet` 引用改为 `,自动优选`。不用订阅自带「自动选择」组：它测 gstatic 会把日本判死，且含香港（Claude 不通）。
- **Apple 全家**：订阅的 `apple.com,DIRECT` / `icloud.com,DIRECT` 把 Apple 服务兜成直连而本网络连不上 Apple（APNs/TestFlight/iCloud/配置服务均超时），故注入 `DOMAIN-SUFFIX,apple.com,自动优选` + `DOMAIN-SUFFIX,icloud.com,自动优选` 整体走代理。
- **微软服务**：订阅把 `microsoft.com / microsoftonline.com / office.com / office365.com / live.com / officecdn` 兜成 DIRECT，本网络直连同样超时，故注入这些域名 → 自动优选（与 Apple 同一注入机制）。
- **国内强制直连**：hf-mirror.com 服务器在东京（SAKURA）、xiaohongshu.com 部分海外 CDN、sun-clan.com，本网络可直连却被 GEOIP 兜进代理，故注入 `DOMAIN-SUFFIX,hf-mirror.com,DIRECT` + `DOMAIN-KEYWORD,xiaohongshu,DIRECT` + `DOMAIN-SUFFIX,sun-clan.com,DIRECT` 强制直连（同一注入机制）。
- **TLS 指纹**：gen_config 对 proxies 段**无 `client-fingerprint` 的 flow 节点**统一注入 `firefox`（跳过 proxy-groups、跳过已有指纹节点）。mihomo 默认指纹的 ClientHello 超 MSS，路由器 GSO 合并大包被中间设备丢前段 → 握手超时（2026-09-01 BoostNet 全部节点 `i/o timeout` 根因）；firefox 指纹包小、单段不分片不受影响。

> 注入的域名都是规则条目，缩进跟随订阅自动适配（旧订阅 4 空格、新订阅 2 空格），缩进不一致会吞掉后续规则破坏 YAML。

## 排障速查

| 现象 | 处理 |
|------|------|
| 海外全不通，日志 `context deadline exceeded` | iptables 本机出站被劫持成自环 → 重跑 `./scripts/install.sh` |
| 海外域名解析成假 IP、fake-ip 不生效 | dnsmasq 需 `restart`（`reload` 不重读 `/tmp/dnsmasq.d/`） |
| 重启后内核 / 订阅消失 | F2FS 吞文件 → 内核重跑 `install.sh`；订阅重跑 `./scripts/update-subscribe.sh` |
| 启动失败，日志 `MMDB invalid` | GeoIP 库被 F2FS 写坏（大小可能正常）→ 启动前 `mihomo -t` 已拦截并自动从备份恢复；备份也坏才需重跑 `install.sh` |
| 某线路到个别站点不通（如日本 → gstatic） | 换**线路**（新加坡/日本），同线路换节点无效（共用一个出口） |
| 整国线路劣化（如日本全部节点 EOF / 高延迟） | judge 最多 10 分钟自动切到别国；急时手动切：在路由器执行 `curl -X PUT -H "Authorization: Bearer $(cat /etc/miniclash/api_secret)" -H 'Content-Type: application/json' -d '{"name":"新加坡组"}' http://127.0.0.1:9090/proxies/自动优选` |
| iPhone / Apple 推送不通（`push.apple.com` 直连超时） | 订阅 `apple.com,DIRECT` 把 APNs 兜成直连而本网络连不上 Apple → init.d 已自动在 rules 最前注入 `push.apple.com → 自动优选`，重启生效 |
| Microsoft 账号 / OneDrive / Office 登录超时 | 订阅把微软域名兜成 DIRECT 而本网络直连不通 → init.d 已注入微软域名 → 自动优选，重启生效 |

## 状态

- [x] 无界面纯配置：4 个 UCI 字段 + 单 init.d + 1 条命令部署
- [x] 订阅本地更新（拉取/base64 检测/过滤日+新 16 节点/上传/重启，路由器不保存订阅地址）
- [x] fake-ip + DoH 防污染 + 节点域名走真实 DNS 防环路
- [x] 自动选优：select 主组 + 国家 url-test 组（组内秒级自愈；judge 每 5 分钟双地址相加跨国裁决，双确认 + 20% margin 防抖）
- [x] watchdog 两层展开上报当前实际节点到 uci（select → 国家组 → 节点）
- [x] 大陆 `GEOIP,CN,DIRECT` 直连
- [x] 内核 + GeoIP 库不入库（体积原因），update-kernel.sh 一条命令下载/更新（含 MD5 校验），install.sh 缺失时自动补齐；启动前 `mihomo -t` 内容校验，F2FS 写坏/丢文件自动从备份恢复
- [x] 真机验证：google / youtube / github 通，大陆直连
- [ ] UDP（TPROXY）— 暂不做，TCP 够日常使用

## 相关文档

- [架构说明](docs/architecture.md) — 目录结构、运行时文件、调用链路
- [mihomo 指南](docs/mihomo-guide.md) — 内核各能力的使用与设计取舍
- [事故报告：2026-09-01 拨号失败](docs/incident-2026-09-01-boostnet-dial-failure.md) — TLS 指纹超 MSS + GSO 丢段根因
