# MiniClash 架构

**一句话**：单 init.d 脚本 + mihomo 内核接管全屋透明代理。UCI 做配置源，REST API 做控制面，订阅节点与规则直通内核不翻译任何协议。

## 双平面总览

```
                    控制面（脚本逻辑，静态/低频）
  ┌─────────────────────────────────────────────────────┐
  │ Mac update-subscribe.sh 拉订阅/过滤/上传 subscribe.yaml │
  │ UCI 配置 → init.d start()                            │
  │   ├─ gen_config()   头部 + 组生成 + 规则注入          │
  │   ├─ start_watchdog() 每 60s 上报当前节点 → uci      │
  │   ├─ judge.sh cron  每 5min 双探针打分 → 跨国裁决    │
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

**控制面**：路由器只做低频编排——生成配置、启动内核、上报节点（订阅由 Mac 上传）。运行期不干预转发路径；持续动作是 watchdog 上报与 judge 定时跨国裁决。

## 文件结构

```
root/etc/config/miniclash      UCI 配置（唯一配置源）
root/etc/init.d/miniclash      全部逻辑（生成/劫持/守护）
root/etc/miniclash/Country.mmdb GeoIP 库（内置，损坏自动重灌）
root/usr/bin/mihomo            内核二进制（内置）
root/usr/share/miniclash/judge.sh 跨国裁决（cron 每 5 分钟，双探针 + 防抖）
scripts/install.sh             root/ → 路由器 / 同步（不覆盖 UCI 配置）
scripts/update-kernel.sh       更新内置内核 + GeoIP（--deploy 同步并重启）
scripts/uninstall.sh           彻底卸载
subscription.url               订阅地址（一行，两个脚本共用）
scripts/update-subscribe.sh    本地拉订阅/过滤日+新+美节点/上传/重启
scripts/traffic.sh             查看套餐剩余流量/重置/到期（信息条目藏在订阅 proxies 段）

运行时（路由器上，非仓库）:
/etc/miniclash/config.yaml     生成的 mihomo 配置
/etc/miniclash/subscribe.yaml  本地上传的订阅（仅日+新+美 20 节点）
/etc/miniclash/api_secret      控制 API 密钥（随机生成）
/etc/miniclash/judge.log       judge 裁决历史（每轮一行；独立轮转保留最后 2500 行 ≈ 8.7 天）
/etc/miniclash/miniclash.log   内核 warning + init.d 事件（轮转保留最后 800 行）
/var/run/miniclash_watchdog.pid  watchdog 进程号
/tmp/miniclash_judge.state     judge 防抖状态（PENDING/COUNT）
```

## 配置（UCI 4 字段）

| 字段 | 含义 |
|------|------|
| `enabled` | 总开关，1 启动 / 0 停止 |
| `group` | 主代理组名（自动优选，select；国家由 judge 裁决） |
| `node` | 当前实际节点（watchdog 每周期上报，仅供查看） |
| `check_interval` | watchdog 上报间隔（秒） |

## 启动序列

```
start()
 1. 校验 enabled 且内核存在、可执行
 2. 校验 subscribe.yaml —— 由 Mac update-subscribe.sh 上传（缺失即报错退出）
 3. gen_config —— 头部 + 组生成 + 规则注入 → config.yaml
 4. wait_wan —— 轮询最多 30s 等 WAN 拿到 IP（治开机时序竞争；手动重启立即返回零开销）
 5. 确保本地 MMDB 在位（缺失先从备份补）→ mihomo -t 真实试读，损坏再从备份恢复
 6. 启动内核（后台）
 7. start_watchdog —— 后台上报循环（两层展开实际节点 → 落盘 uci node）
 8. ipt_start + dns_start —— 建立透明代理劫持与 DNS 联动
 9. 关闭 WAN GSO/TSO —— 隧道内 TLS record 超 MSS 被网卡合并大包、中间设备丢前段（配合指纹注入）
10. 幂等安装 judge cron —— 每 5 分钟跨国裁决
11. BOOT=1 前台跑一次 judge —— 实测打分直接进当前最优国家（开机直选，绕过双确认；约 6s）
```

## 配置生成（gen_config）四个要点

**① 头部自有，节点/规则直通**：端口 / DNS / API 三块由脚本写死；上传订阅的 proxies（仅日+新+美 20 节点）与 rules 原样交给内核，订阅自带的 port/dns 等段 awk 不输出——保证运行时行为可预期。

**② 自动优选组（select + 国家 url-test）**：从上传订阅提取节点名（过滤在本地完成），按固化国家顺序（日本,新加坡,美国）以前缀归集，在 rules 段前生成——
- select 主组：`{ name: 自动优选, type: select, proxies: ['日本组','新加坡组','美国组'] }`
- 每国一个 url-test 组：`{ name: 新加坡组, type: url-test, proxies: [新加坡1…], url: 'github.com/generate_204', interval: 60, tolerance: 500, expected-status: 200/204 }`

健康检查用 `expected-status: 200/204`：只认真实 204（generate_204 固定返回），防运营商劫持返回假 200 被误判为节点健康。

并把 rules 里所有 `,BoostNet` 引用改为 `,自动优选`。不用订阅自带「自动选择」组：它测 gstatic 会把日本判死，且含香港（Claude 不通）。两层自愈：单节点故障国家组内核秒级切换；整国劣化 judge 裁决跨国（见下）。

**③ 海外服务例外注入**：在 `rules:` 最前插入「订阅 DIRECT 兜底、但本网络直连不通」的服务域名 → 自动优选：`push.apple.com`（Apple 推送，APNs 长连接），以及 `microsoft.com / microsoftonline.com / office.com / office365.com / live.com / officecdn`（Microsoft 账号 / OneDrive / Office）。原因是订阅把 `apple.com`、微软域名都兜成 DIRECT，而本网络直连 Apple / Microsoft 服务器 TCP 超时；走代理则 TLS 握手完整成功（实测验证）。

**④ 缩进自适应**：注入行必须与订阅规则条目缩进**逐字节一致**。gen_config 用 awk 取 rules 首元素缩进，统一对齐组与规则注入；缩进不一致会让 YAML 解析吞掉 `rules[0]` 后续所有规则，表现为 "proxy [自动优选 - ...] not found"。

**⑤ TLS 指纹**：gen_config 对 proxies 段**无 `client-fingerprint` 的 flow 节点**统一注入 `firefox`（跳过已有指纹节点）。mihomo 默认指纹的 ClientHello 超 MSS(1452)，路由器 GSO/TSO 合并大包被中间设备（光猫）丢前段 → SACK 只确认尾部 → 握手永不完整 → `i/o timeout`；firefox 指纹包小单段不分片。配合 start() 关 WAN GSO/TSO，解决隧道内大数据传输间歇失败（2026-09-01 BoostNet 恢复后拨号全灭根因）。

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

## 自动选优（select 主组 + 国家 url-test + judge 裁决）

主组「自动优选」是 **select** 组，成员是各**国家 url-test 组**（新加坡组/日本组/美国组）。国家组每 60s 测 `github.com/generate_204` 选组内延迟最优（`tolerance: 500` 防组内噪声横跳）——单节点故障内核秒级自愈，脚本不干预。

**judge 跨国裁决**（`/usr/share/miniclash/judge.sh`，cron 每 5 分钟）：起因 2026-09-21 日本整国劣化 4+ 小时，旧 fallback 结构的备用池全是同国节点，结构上无法逃生。judge 对每国每节点实测**双目标** `github.com/generate_204` + `google.com/generate_204`（单探针对半死节点有盲区：日本对 Google 系业务 EOF 时 GitHub 探针仍返 204）；国家分 = 最快 2 个双活节点的 GitHub 延迟均值，活节点不足 2 个 = 不可用。

**防抖**（状态 `/tmp/miniclash_judge.state`）：当前国家实时从 select API 读；连续 2 次（10 分钟）同一别国领先、**且**当前国慢 20%（当前国不可用直接满足）才 `PUT /proxies/自动优选 {"name":"X组"}`。双确认 + margin，杜绝打地鼠。

**开机直选（BOOT 模式）**：select 启动默认固定选第一个成员（新加坡），并非实时最优。init.d start() 末尾以 `BOOT=1` 前台跑一次 judge，绕过双确认、按实测分数直接 PUT 进最优国家（约 6s）；若三国都不可用则安全保持默认。cron 常规轮次不带 BOOT，防抖不变。

**每轮落日志**：judge 每次运行（含未切换）都在独立的 judge.log 记一行 `[judge] 新加坡:291ms, 日本:413ms | 保持 新加坡`，巡检直接 tail 回溯；独立文件避免被量大的内核 warning 冲掉历史。两份日志超 512KB 都按行原地截断（judge.log 留 2500 行 ≈ 8.7 天、miniclash.log 留 800 行），不切半行、inode 不变，防撑爆闪存且不影响 mihomo 持续写入。

**为什么不用订阅自带「自动选择」组**：它测 gstatic（`http://www.gstatic.com/generate_204`），而本网络日本 gstatic 全不通（日本出口到 Google 静态 CDN 路由问题），会把日本判死；且组内含香港——香港 GitHub 快但 Claude/ChatGPT 不通。

**为什么不用纯 url-test 跨国**：跨国延迟随测速波动时纯 url-test 会在国家组间横跳，切换瞬间断连。select 由 judge 双确认裁决，慢半拍但稳。

## watchdog（节点上报）

watchdog 不驱动切换——组内切换交给内核、跨国切换交给 judge。watchdog 每 `check_interval` 秒读 `GET /proxies/自动优选`，`now` 是国家组名（新加坡组），再查 `/proxies/新加坡组` 展开第二层取实际节点，落盘到 UCI `node`（供查看/诊断），仅在变化时写。

**为什么 judge 取代固定顺序脚本切换**：2026-08-18 下午新加坡全线劣化，脚本按固定顺序"选第一个可达的"连续 5 次切换（8→2→8→3→7→2）打地鼠——候选全是劣化节点时切谁都不稳。judge 双确认 + 20% margin 后才动，稳定无风暴。

## 关键设计决策

| 决策 | 为什么 |
|------|--------|
| 单 init.d 脚本，无界面 | 链路简单，出问题一眼能查；配置即文档 |
| 节点与规则直通内核 | 不翻译协议，订阅格式演进由内核兜底 |
| 只劫持 PREROUTING | 防自环（内核连节点被重定向回自己） |
| 订阅本地过滤：base64 检测 + 20 节点数校验 | 订阅常被 base64 包裹；节点数不符立即拒绝，防脏订阅上传 |
| 内核/GeoIP 内置 root/ | 一条命令恢复，防 F2FS 吞文件 |
| select 主组 + 国家 url-test 两层结构 | 单节点故障组内核秒级自愈；整国劣化 judge 裁决可跨国逃生（2026-09-21 旧 fallback 同国备用池无法逃生） |
| judge 双确认 + 20% margin 才跨国切换 | 杜绝"打地鼠"切换风暴（2026-08-18 教训）与测速噪声误判；最坏 10 分钟延迟 |
| 国家 url-test 加 `tolerance: 500` | 组内节点延迟接近且波动，须领先 500ms 才切，压住无效切换 |
| judge 双探针（GitHub + Google） | 单探针对半死节点有盲区（GitHub 返 204、Google 业务 EOF），双目标任一失败即判死 |
| 自动优选组按国家归集 + GitHub 判据 | 避开订阅「自动选择」组的 gstatic 陷阱（判死日本）与香港（Claude 不通） |
| 海外被 DIRECT 兜底的服务注入代理 | 订阅把 apple.com / 微软域名兜成 DIRECT，本网络直连海外不通（实测超时），故在 rules 最前注入走代理 |
| 无指纹节点注入 `client-fingerprint: firefox` | 默认指纹 ClientHello 超 MSS，路由器 GSO 合并大包被中间设备丢前段 → 握手超时（2026-09-01 拨号全灭根因）；firefox 指纹包小单段不分片 |
| 关闭 WAN GSO/TSO | 隧道内 TLS record 超 MSS 被网卡合并大包、中间设备丢前段，配合指纹注入根治大数据传输间歇失败 |
| watchdog 只上报不切换 | 组内切换交给内核、跨国交给 judge，脚本仅两层展开记录当前节点供查看 |
| 开机 wait_wan + 启动前确保 MMDB 在位 | 2026-09-25 冷启动时 WAN/MMDB 未就绪，mihomo 运行时联网下 MMDB 失败反复 fatal（折腾 15 分钟）；先就绪再拉起，一次成功 |
