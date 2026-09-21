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
    option url 'https://sub.boost1.shop/…'  # 订阅地址（已写死 BoostNet）
    option force_update '0'             # 1 时重启强制重新下载订阅
    option group '自动优选'             # 主代理组名（fallback：默认节点 + 备用 url-test）
    option node '日本1'                 # 当前实际节点（watchdog 自动更新，仅供查看）
    option nodes '日本1,日本2,日本3,日本4'  # 自动优选：第 1 个为默认节点，其余为备用候选
    option check_interval '60'          # 节点上报间隔（秒）
```

改配置 → `uci commit miniclash` → `/etc/init.d/miniclash restart`。

**切换机场**：一条命令（机场信息在 `airports/`，脚本自动写 UCI → 强制拉订阅 → 重启 → 恢复 force_update）：

```bash
./scripts/airport-switch.sh boostnet   # 切回 BoostNet（主力）
```

## 部署

```bash
./scripts/install.sh        # 一键安装到路由器（内置内核+GeoIP库，不覆盖已有配置）
./scripts/update-kernel.sh  # 更新内置 mihomo 内核 + GeoIP 库（加 --deploy 同步并重启）
./scripts/uninstall.sh      # 彻底卸载
./scripts/airport-switch.sh # 一键切换机场（配置在 airports/<机场名>.conf）
```

机场信息留档在 `airports/` 目录（`boostnet.conf`，含订阅地址 + 候选 + 备注），切换：`./scripts/airport-switch.sh <机场名>`（不带参数列出可用机场）。

订阅地址 / 候选 / 默认节点已写死在 config 里，无需手工填。首次安装后直接启用（模板已 `enabled=1`）：

```bash
/etc/init.d/miniclash enable
/etc/init.d/miniclash start
```

### 更新内核与 GeoIP 库

```bash
./scripts/update-kernel.sh            # 仅更新项目内置文件
./scripts/update-kernel.sh --deploy   # 更新后同步到路由器并重启服务
```

自动对比 mihomo 最新 release，版本相同则跳过内核；GeoIP 库（country.mmdb）每次拉最新。默认 linux-arm64（mt7981 路由器），可用 `PLATFORM=xxx` 覆盖。

## 日常使用

- 启动 / 停止 / 重启：`/etc/init.d/miniclash {start|stop|restart}`
- 看状态：`/etc/init.d/miniclash status`
- 看当前节点：`uci get miniclash.core.node`（watchdog 每周期自动更新）
- 更新订阅：`uci set miniclash.core.force_update='1' && uci commit miniclash && /etc/init.d/miniclash restart`（force_update 会在订阅下载成功后自动恢复为 0，无需手动回写）
- 切换机场：`./scripts/airport-switch.sh <机场名>`（`boostnet`，配置在 `airports/`）
- 日志智能分诊：`./scripts/diagnose.sh`（TypeSafe Jev 判断节点故障 / 故障类型 / 健康度，需 `TYPESAFE_API_KEY` 与 jq；日志自动脱敏后出网）
- 自动选优：主组「自动优选」是 fallback 组——`nodes` 第 1 个为**默认节点**（可达即锁定，稳定优先），其余为**备用候选**（url-test 自动选优，tolerance 500ms 防抖动），默认节点劣化才切备用。`node` 由 watchdog 上报记录当前实际节点。想固定某节点：把 `nodes` 只留它，重启

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

**④ 自动选优组**（`external-controller: 9090` + `secret`）
主组「自动优选」是 fallback 组：`nodes` 第 1 个为**默认节点**（可达即锁定，稳定优先），其余为**备用候选**（url-test 组「自动优选-备用」，每 60s 测 GitHub 自动选延迟最优，tolerance 500ms 防抖动）。默认节点劣化才切备用组，避免延迟接近的候选因测速噪声横跳断连。watchdog 只读 `GET /proxies/自动优选`（备用组选中时展开一层）把当前实际节点落盘到 `node` 供查看，不再驱动切换。

**⑤ 订阅 YAML 直通**
`proxies:` 起的部分原样交给内核：45 个 anytls 节点、proxy-groups（BoostNet / 自动选择 / 故障转移）、rules（含 `GEOIP,CN,DIRECT` 大陆直连）全部由内核原生解析、健康检查（url-test）和分流。MiniClash 只覆盖端口 / DNS / API 三块头部，不翻译任何协议。订阅源常在 YAML 头塞信息伪装条目（剩余流量/到期日/官网），dashboard 会显示但不影响出网——所有规则走「自动优选」。

五处例外：
- **自动优选组**：init.d 在 proxy-groups 段注入 `{ name: 自动优选, type: fallback, proxies: [默认节点, '自动优选-备用'], url: 'github.com/generate_204', interval: 60, expected-status: 200/204 }` + `{ name: 自动优选-备用, type: url-test, proxies: [其余候选], url: 'github.com/generate_204', interval: 60, tolerance: 500, expected-status: 200/204 }`（默认节点 = `nodes` 第 1 个，可达即锁定；劣化才切备用 url-test 组；expected-status 只认真实 204 防劫持假 200 误判），并把 rules 里所有 `,BoostNet` 引用改为 `,自动优选`。不用订阅自带「自动选择」组：它测 gstatic 会把日本判死，且含香港（Claude 不通）。
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
| 重启后内核 / 订阅消失 | F2FS 恢复吞文件 → 重跑 `install.sh` 再 `start`（订阅自动重下） |
| 某线路到个别站点不通（如日本 → gstatic） | 换**线路**（日本/香港/台湾…），同线路换节点无效（共用一个出口） |
| iPhone / Apple 推送不通（`push.apple.com` 直连超时） | 订阅 `apple.com,DIRECT` 把 APNs 兜成直连而本网络连不上 Apple → init.d 已自动在 rules 最前注入 `push.apple.com → 自动优选`，重启生效 |
| Microsoft 账号 / OneDrive / Office 登录超时 | 订阅把微软域名兜成 DIRECT 而本网络直连不通 → init.d 已注入微软域名 → 自动优选，重启生效 |

## 状态

- [x] 无界面纯配置：7 个 UCI 字段（含默认值容错）+ 1 个脚本 + 1 条命令部署
- [x] 订阅下载（YAML 直通，5MB 上限，base64 检测，3 次重试 + 30s 超时）
- [x] fake-ip + DoH 防污染 + 节点域名走真实 DNS 防环路
- [x] 自动选优：fallback 组（默认节点可达即锁定，劣化才切备用 url-test 组，tolerance 500 防抖动）
- [x] watchdog 上报当前实际节点到 uci（fallback 选中备用组且无活跃代理时返回 DIRECT，防脏数据）
- [x] 大陆 `GEOIP,CN,DIRECT` 直连
- [x] 内核 + GeoIP 库内置，update-kernel.sh 一条命令更新（含 MD5 校验防损坏），F2FS 丢文件 `install.sh` 恢复
- [x] 真机验证：google / youtube / github 通，大陆直连
- [ ] UDP（TPROXY）— 暂不做，TCP 够日常使用

## 相关文档

- [新增机场](docs/add-airport.md) — 配置文件格式、字段约束、切换与验证步骤
- [架构说明](docs/architecture.md) — 目录结构、运行时文件、调用链路
- [mihomo 指南](docs/mihomo-guide.md) — 内核各能力的使用与设计取舍
