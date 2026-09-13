# MiniClash 架构

**一句话**：单 init.d 脚本 + mihomo 内核接管全屋透明代理。UCI 做配置源，REST API 做控制面，`proxies:` 起的订阅直通内核不翻译任何协议。

架构变更记录见 [CHANGELOG.md](CHANGELOG.md)。

## 双平面总览

```
                    控制面（脚本逻辑，静态/低频）
  ┌─────────────────────────────────────────────────────┐
  │ UCI 配置 → init.d start()                            │
  │   ├─ subscribe()    下载订阅 → subscribe.yaml        │
  │   ├─ gen_config()   头部 + 订阅直通 + 自动优选注入    │
  │   ├─ start_watchdog() 每 60s 上报当前节点 → uci      │
  │   └─ ipt_start / dns_start  建立劫持与 DNS          │
  └──────────────┬──────────────────────┬──────────────┘
                 │ REST API (9090)      │ 写配置文件
                 ▼                      ▼
              ┌─────────────────────────────────┐
              │           mihomo 内核           │
              │  fake-ip DNS(7874) redir(7892) │
              └───────┬──────────────┬─────────┘
                      │ 规则分流      │
              ┌───────┴─────┐  ┌─────┴──────┐
              │ 节点 anytls │  │ GEOIP,CN   │
              │ → 海外      │  │ → DIRECT   │
              └─────────────┘  └────────────┘
                    数据面（LAN 设备流量，高频）
  LAN 设备 ── DNS → dnsmasq → 127.0.0.1:7874 (fake-ip)
          └─ TCP → iptables REDIRECT → 7892
```

**数据面**：LAN 设备的 DNS 被 dnsmasq 指向内核 fake-ip，TCP 被 iptables 全量 REDIRECT 进内核；内核还原真实域名后按订阅规则分流。

**控制面**：脚本只做低频编排——拉订阅、生成配置、启动内核、上报节点。运行期不干预转发路径与节点选择，唯一持续动作是 watchdog 上报。

## 文件结构

```
root/etc/config/miniclash      UCI 配置（唯一配置源）
root/etc/init.d/miniclash      全部逻辑（下载/生成/劫持/自动优选/守护）
root/etc/miniclash/Country.mmdb GeoIP 库（内置，损坏自动重灌）
root/usr/bin/mihomo            内核二进制（内置）
scripts/install.sh             root/ → 路由器 / 同步（不覆盖 UCI 配置）
scripts/update-kernel.sh       更新内置内核 + GeoIP（--deploy 同步并重启）
scripts/uninstall.sh           彻底卸载
scripts/airport-switch.sh      一键切换机场（读 airports/<机场名>.conf → 写 UCI → 重启）
airports/boostnet.conf         BoostNet 机场信息（订阅 URL + 候选 + 备注）

运行时（路由器上，非仓库）:
/etc/miniclash/config.yaml     生成的 mihomo 配置
/etc/miniclash/subscribe.yaml  下载的订阅（proxies: 起）
/etc/miniclash/api_secret      控制 API 密钥（随机生成）
/var/run/miniclash_watchdog.pid  watchdog 进程号
```

## 配置（UCI 7 字段）

| 字段 | 含义 |
|------|------|
| `url` | 订阅地址 |
| `enabled` | 总开关，1 启动 / 0 停止 |
| `force_update` | 1 时重启强制重下订阅 |
| `group` | 主代理组名（自动优选，fallback：默认节点 + 备用 url-test） |
| `node` | 当前实际节点（watchdog 每周期上报，仅供查看） |
| `nodes` | 自动优选：第 1 个为默认节点（可达即锁定），其余为备用 url-test 候选 |
| `check_interval` | watchdog 上报间隔（秒） |

## 启动序列

```
start()
 1. 校验 enabled 且内核存在、可执行
 2. subscribe —— 首次或 force_update 时下载
      curl 15s 超时 + 5MB 上限 + UA → base64 检测解码 → 校验含 proxies: 段
 3. gen_config —— 头部 + 订阅直通 + 自动优选注入 → config.yaml
 4. 启动内核（后台）
 5. start_watchdog —— 后台上报循环（读自动优选实际节点 → 落盘 uci node）
 6. ipt_start + dns_start —— 建立透明代理劫持与 DNS 联动
 7. 关闭 WAN GSO/TSO —— 隧道内 TLS record 超 MSS 被网卡合并大包、中间设备丢前段（配合指纹注入）
```

## 配置生成（gen_config）四个要点

**① 头部自有，订阅直通**：端口 / DNS / API 三块由脚本写死；订阅只取 `proxies:` 起的部分，proxy-groups 和 rules 原样交给内核。订阅自带的 port/dns 段被丢弃——保证运行时行为可预期。

**② 自动优选组（fallback）**：在 proxy-groups 段注入两个组——
- `{ name: 自动优选, type: fallback, proxies: [默认节点, '自动优选-备用'], url: 'github.com/generate_204', interval: 60, expected-status: 200/204 }`（默认节点 = `nodes` 第 1 个，可达即锁定）
- `{ name: 自动优选-备用, type: url-test, proxies: [其余候选], url: 'github.com/generate_204', interval: 60, tolerance: 500, expected-status: 200/204 }`

两个组健康检查都用 `expected-status: 200/204`：只认真实 204（generate_204 固定返回），防运营商劫持返回假 200 被误判为节点健康。

并把 rules 里所有 `,BoostNet` 引用改为 `,自动优选`（流量走自动选优）。稳定优先：默认节点通就用它，劣化才切备用 url-test 组——根治"延迟接近的候选因测速噪声横跳断连"（2026-09-01）。不用订阅自带「自动选择」组：它测 gstatic 会把日本判死，且含香港（Claude 不通）。

**③ 海外服务例外注入**：在 `rules:` 最前插入「订阅 DIRECT 兜底、但本网络直连不通」的服务域名 → 自动优选：`push.apple.com`（Apple 推送，APNs 长连接），以及 `microsoft.com / microsoftonline.com / office.com / office365.com / live.com / officecdn`（Microsoft 账号 / OneDrive / Office）。原因是订阅把 `apple.com`、微软域名都兜成 DIRECT，而本网络直连 Apple / Microsoft 服务器 TCP 超时；走代理则 TLS 握手完整成功（实测验证）。

**④ 缩进自适应**：注入行必须与订阅规则条目缩进**逐字节一致**。gen_config 用 awk 取 proxy-groups / rules 首元素的缩进，动态对齐注入（旧订阅 4 空格、新订阅 2 空格都适配）；缩进不一致会让 YAML 解析吞掉 `rules[0]` 后续所有规则，表现为 "proxy [自动优选 - ...] not found"。改订阅源时须复验缩进。

**⑤ TLS 指纹**：gen_config 对 proxies 段**无 `client-fingerprint` 的 flow 节点**统一注入 `firefox`（跳过 proxy-groups、跳过已有指纹节点）。mihomo 默认指纹的 ClientHello 超 MSS(1452)，路由器 GSO/TSO 合并大包被中间设备（光猫）丢前段 → SACK 只确认尾部 → 握手永不完整 → `i/o timeout`；firefox 指纹包小单段不分片。配合 start() 关 WAN GSO/TSO，解决隧道内大数据传输间歇失败（2026-09-01 BoostNet 恢复后拨号全灭根因）。

## 透明代理（iptables）

```
PREROUTING TCP → MINICLASH 链 → 排除内网段/组播 → REDIRECT 7892
```

**只劫持 LAN 转发流量**（PREROUTING），**本机出站不劫持**——否则内核连接节点的那一跳会被重定向回自己，形成自环，表现为 `context deadline exceeded`。这是最容易回退的故障，重跑 install.sh 即可修复。

## DNS（fake-ip 三层防污染）

- **fake-ip**：`listen 127.0.0.1:7874` + `enhanced-mode: fake-ip`，域名映射到 `198.18.0.1/16`，客户端永远碰不到真实 IP；连接时内核还原真实域名再匹配规则。
- **nameserver**：国内 DoH（doh.pub / alidns）主解析，不污染海外域名。
- **fallback**：明文 DNS 兜底；**proxy-server-nameserver**：节点域名用真实 DNS，防 fake-ip 化导致内核连节点死循环。
- **联动**：dnsmasq 上游指向 7874，必须 `restart`（`reload` 不重读 `/tmp/dnsmasq.d/` 新文件）。

## 自动选优（fallback：默认节点 + 备用 url-test）

主组「自动优选」是 **fallback** 组：`proxies: [默认节点, '自动优选-备用']`，默认节点（`nodes` 第 1 个）可达即锁定，脚本不干预——稳定优先。默认节点劣化（测 GitHub 失败）才切「自动优选-备用」，它是 url-test 组（其余候选，每 60s 测 `github.com/generate_204`，`tolerance: 500` 防抖动，候选须领先 500ms 才切换）。2026-09-01 起：BoostNet 默认日本1（gstatic 恒定 129ms 最稳），备用日本2/3/4。

**为什么不用订阅自带「自动选择」组**：它测 gstatic（`http://www.gstatic.com/generate_204`），而本网络日本 gstatic 全不通（日本出口到 Google 静态 CDN 路由问题），会把日本判死；且组内含香港——香港 GitHub 快但 Claude/ChatGPT 不通。自定义「自动优选」限定候选池 + 用 GitHub 判据，与飞哥实际场景（GitHub/HF/Google/CivitAI/Claude/ChatGPT）一致。

**为什么默认节点 + 备用、而非纯 url-test 全候选**：日本节点延迟接近（129~391ms）且波动，纯 url-test 会因测速噪声在 4 候选间横跳，切换瞬间断连（表现为大请求间歇失败）。fallback 让默认节点通就锁它，仅真正劣化才动备用组——根治"延迟接近的候选因测速噪声横跳断连"。

## watchdog（节点上报）

主组是 fallback 组后，watchdog 不再驱动切换——切换交给内核。watchdog 每 `check_interval` 秒读 `GET /proxies/自动优选` 拿到当前实际节点，落盘到 UCI `node`（供查看/诊断），仅在变化时写。fallback 选中备用组时 `now` 是组名「自动优选-备用」，watchdog 会再查 `/proxies/自动优选-备用` 展开一层取实际节点。

**为什么废弃脚本切换**：2026-08-18 下午新加坡全线劣化，脚本按固定顺序"选第一个可达的"连续 5 次切换（8→2→8→3→7→2）打地鼠——候选全是劣化节点时切谁都不稳。改为内核 fallback 后，默认节点可用即锁它，劣化自动落备用组，稳定无风暴。

## 关键设计决策

| 决策 | 为什么 |
|------|--------|
| 单 init.d 脚本，无界面 | 链路简单，出问题一眼能查；配置即文档 |
| 订阅 `proxies:` 起直通 | 不翻译协议，订阅格式演进由内核兜底 |
| 只劫持 PREROUTING | 防自环（内核连节点被重定向回自己） |
| 订阅下载后 base64 检测 + YAML 校验 | 订阅常被 base64 包裹；提前拒绝垃圾内容 |
| 内核/GeoIP 内置 root/ | 一条命令恢复，防 F2FS 吞文件 |
| 主组用 fallback（默认节点 + 备用 url-test）而非脚本切换 | 默认节点可达即锁定，劣化才切备用组；内核持续跟踪、杜绝固定顺序"打地鼠"快切（2026-08-18 实测教训 + 2026-09-01 噪声横跳教训） |
| 备用 url-test 加 `tolerance: 500` | 候选延迟接近（129~391ms）且波动，纯 url-test 因测速噪声横跳断连；须领先 500ms 才切，压住无效切换 |
| 自动优选组限定候选 + GitHub 判据 | 避开订阅「自动选择」组的 gstatic 陷阱（判死日本）与香港（Claude 不通） |
| 海外被 DIRECT 兜底的服务注入代理 | 订阅把 apple.com / 微软域名兜成 DIRECT，本网络直连海外不通（实测超时），故在 rules 最前注入走代理 |
| 无指纹节点注入 `client-fingerprint: firefox` | 默认指纹 ClientHello 超 MSS，路由器 GSO 合并大包被中间设备丢前段 → 握手超时（2026-09-01 拨号全灭根因）；firefox 指纹包小单段不分片 |
| 关闭 WAN GSO/TSO | 隧道内 TLS record 超 MSS 被网卡合并大包、中间设备丢前段，配合指纹注入根治大数据传输间歇失败 |
| watchdog 只上报不切换 | 切换交给内核，脚本仅记录当前节点供查看（fallback 选中备用组时展开一层取实际节点） |
