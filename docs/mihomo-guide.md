# mihomo 内核使用说明（MiniClash 视角）

MiniClash 不翻译任何协议，直接用 mihomo 内核的能力。本文对照 mihomo 官方文档（[meta-docs](https://github.com/metacubex/meta-docs)，按 2026-09 版整理）把内核每个模块讲清楚：**官方语义是什么 → MiniClash 怎么用的 → 怎么验证**。内核版本 v1.19.30。

- 运行时配置文件：`/etc/miniclash/config.yaml`（由 `/etc/init.d/miniclash` 的 `gen_config()` 生成）
- 设计全貌见 [architecture.md](architecture.md)

---

## 0. MiniClash 用到的内核模块

```
                     mihomo 内核
   ┌──────────────────────────────────────────┐
   │ general   端口/模式/日志/API 头部（自写）    │
   │ proxies   订阅 anytls 节点直通（不翻译）    │
   │ proxy-groups 自动优选=select+国家url-test  │
   │ rules     订阅规则直通 + 注入 EXTRA        │
   │ dns       fake-ip 国内外分流              │
   │ listeners redir(劫持)/mixed(测试)/tproxy    │
   │ api       9090 watchdog 上报节点           │
   └──────────────────────────────────────────┘
```

---

## 1. 通用配置（general）

### 1.1 端口与监听

| 字段 | 官方语义 | MiniClash 值 | 用途 |
|------|----------|-------------|------|
| `mixed-port` | 同时支持 HTTP(S) 与 SOCKS5 | `7893` | **本机/局域网测试口**：`curl -x http://127.0.0.1:7893` |
| `redir-port` | 透明代理（仅 Linux/macOS），**只能 TCP** | `7892` | iptables REDIRECT 劫持 LAN 设备 TCP |
| `tproxy-port` | 透明代理，**TCP + UDP** | `7895` | 预留，当前未用（UDP 暂不做） |
| `allow-lan` | 允许其他设备经代理端口上网 | `true` | 全屋透明代理的前提 |
| `bind-address` | 绑定地址，默认 `*` | 未设（默认全部） | — |
| `lan-allowed-ips` / `lan-disallowed-ips` | 允许/禁止的局域网来源段 | 未设（默认 `0.0.0.0/0`、`::/0`） | — |

> `redir` 只能代理 TCP，要 UDP 得用 `tproxy` + TPROXY 规则。MiniClash 当前只做 TCP（`tproxy-port` 预留，改 TPROXY 时启用）。

### 1.2 运行模式与日志

| 字段 | 官方语义 | MiniClash 值 |
|------|----------|-------------|
| `mode` | `rule` 规则匹配 / `global` 全局代理 / `direct` 全局直连 | `rule` |
| `log-level` | `silent/error/warning/info/debug` | `warning`（错误与警告，不刷屏） |
| `ipv6` | 是否接受 IPv6 流量，默认 `true` | `false`（本期网络无 IPv6 需求） |
| `find-process-mode` | 进程匹配：`always/strict/off`，**路由器推荐 `off`** | 未设（默认 `strict`） |

> 官方明确：路由器上推荐 `find-process-mode: off`——匹配进程在路由器上有额外开销且意义不大。MiniClash 未设，如需更省可加 `off`。

### 1.3 API（external-controller）

| 字段 | 官方语义 | MiniClash 值 |
|------|----------|-------------|
| `external-controller` | REST API 监听地址，`127.0.0.1:9090` 可改 `0.0.0.0` 监听所有 | `0.0.0.0:9090` |
| `secret` | API 访问密钥 | 随机生成（`/etc/miniclash/api_secret`） |
| `external-doh-server` | API 端口开 DoH（不验证 secret，慎开） | 未用 |
| `external-ui` | 把面板静态资源挂在 API `/ui` | 未用（无界面，符合极简） |

### 1.4 其他值得知道的

| 字段 | 官方语义 | MiniClash |
|------|----------|-----------|
| `profile.store-selected` | 持久化 API 对策略组的选择，重启沿用 | 未设（select 重启后默认选第一个国家组，judge 会重新裁决，行为一致） |
| `profile.store-fake-ip` | 持久化 fake-ip 映射表 | 未设（可选，加速重启后 DNS） |
| `unified-delay` | 统一 RTT 计算，消除不同类型节点握手差异 | 未设（单协议 anytls，差异不大） |
| `tcp-concurrent` | 用 DNS 解析出所有 IP 并发连接，取首个成功 | 未设（默认关，减少重复连接） |
| `routing-mark` | Linux 出站连接流量标记 | 未用（iptables 单链无需） |
| `geodata-loader` | GEO 加载器，`memconservative` 为小内存设备默认 | 未设（默认即可，mt7981 够用） |

---

## 2. 透明代理（iptables 配合）

**官方语义**：`redir-port`/`tproxy-port` 提供透明代理入站，配合 iptables 把流量 REDIRECT/TPROXY 进内核；内核从 socket 取回原始目标地址（SO_ORIGINAL_DST）再按规则分流。

**MiniClash 用法**（`ipt_start()`）：

```sh
iptables -t nat -N MINICLASH
iptables -t nat -A MINICLASH -d <内网/本机/组播段> -j RETURN   # 排除 127/192.168/10/172.16/224/0
iptables -t nat -A MINICLASH -p tcp -j REDIRECT --to-ports 7892
iptables -t nat -A PREROUTING -p tcp -j MINICLASH              # 只劫持转发流量
```

**关键约束**：
- 只挂 `PREROUTING`（LAN 转发），**不劫持本机出站**——否则内核连节点的连接被重定向回自己，自环报 `context deadline exceeded`
- 本机 curl 直连海外不走代理，**测试必须 `-x http://127.0.0.1:7893` 走 mixed 口**

**验证**：
```sh
iptables -t nat -L MINICLASH -n          # 看链规则
curl -x http://127.0.0.1:7893 -s -o /dev/null -w '%{http_code}' https://github.com   # 走内核实测
```

---

## 3. 代理组（proxy-groups）

### 3.1 组类型

| 类型 | 官方语义 | MiniClash |
|------|----------|-----------|
| `select` | 手动选择，默认选第一个（或 `default-selected`） | ✅ 主组「自动优选」（judge 经 API 裁决国家） |
| `url-test` | 定时测速，**自动选延迟最优** | ✅ 国家组「新加坡组」「日本组」 |
| `fallback` | 当前节点超时，**按顺序选第一个可用** | 未用 |
| `load-balance` | 负载均衡：`round-robin` / `consistent-hashing` / `sticky-sessions` | 未用 |
| `relay` | 链路代理（如 A→B→C 级联） | 未用 |

> **select 与 url-test 的分工**：select 是"裁决层"——国家选择由 judge 双确认后经 API 指定，稳定优先；url-test 是"组内择优"——一直测速选延迟最低，性能优先。两层组合出"组内秒级自愈 + 国家 10 分钟防抖裁决"。

### 3.2 通用字段（健康检查核心）

| 字段 | 官方语义 | MiniClash 值 |
|------|----------|-------------|
| `name` | 组名，特殊符号需引号 | `自动优选` / `新加坡组` / `日本组` |
| `type` | 组类型 | `select` / `url-test` |
| `proxies` | 引入出站代理或其他策略组 | select 引入国家组；国家组引入节点 |
| `use` | 引入代理集合（proxy-providers） | 未用（节点走订阅 `proxies:`） |
| `url` | 健康检查测试地址 | `https://github.com/generate_204` |
| `interval` | 健康检查间隔，不为 0 启用定时测试（秒） | `60` |
| `lazy` | 默认 `true`：未被选中时不做测速 | 未设（全屋常流量，意义小） |
| `tolerance` | url-test 切换容差（ms），新候选须领先此值才切 | `200` |
| `expected-status` | 健康检查期望状态码，默认 `*`（任意都算通） | `200/204`（只认真实 204） |
| `timeout` | 健康检查超时（ms） | 未设（默认 5000） |
| `max-failed-times` | 最大失败次数，超过触发强制健康检查，默认 5 | 未设 |
| `filter` / `exclude-filter` | 按正则筛/排除节点（仅对 use/include-all 生效） | 未用（节点本地过滤后经订阅显式给定） |
| `disable-udp` | 禁用该组 UDP | 未设 |

### 3.3 MiniClash 的实际结构

```yaml
# select 主组：成员为国家组，judge 经 API 裁决
- { name: 自动优选, type: select, proxies: ['日本组','新加坡组'] }
# 国家组：组内 url-test 择优（新加坡8节点、日本8节点，节点本地过滤后上传）
- { name: 新加坡组, type: url-test, proxies: ['新加坡1',…,'新加坡8'],
    url: 'https://github.com/generate_204', interval: 60, tolerance: 200, expected-status: 200/204 }
- { name: 日本组, type: url-test, proxies: ['日本1',…,'日本8'],
    url: 'https://github.com/generate_204', interval: 60, tolerance: 200, expected-status: 200/204 }
```

行为：国家组内单节点劣化 **60s 内自动切**（tolerance 200ms 防组内噪声）；整国劣化由 judge 对 GitHub 主站 + githubassets 双地址（都活才）计时相加实测、**双确认 + 20% margin** 后切国家组（见 architecture.md「自动选优」）。2026-09-01 拨号事故见 [事故报告](incident-2026-09-01-boostnet-dial-failure.md)。

**验证**：
```sh
curl -s -H "Authorization: Bearer $(cat /etc/miniclash/api_secret)" \
  http://127.0.0.1:9090/proxies/自动优选   # now 是国家组名，再查 /proxies/新加坡组 看实际节点
```

---

## 4. DNS（fake-ip 国内外分流）

### 4.1 解析模式

| 字段 | 官方语义 | MiniClash 值 |
|------|----------|-------------|
| `enable` | 关则用系统 DNS | `true` |
| `listen` | DNS 监听（udp/tcp） | `127.0.0.1:7874` |
| `enhanced-mode` | `fake-ip`（域名映射假 IP）/ `redir-host`（返回真实 IP） | `fake-ip` |
| `fake-ip-range` | fake-ip 网段 | `198.18.0.1/16` |
| `fake-ip-filter` | 这些域名不下发 fake-ip，走真实解析 | `+.lan` / `+.local` / `+.myzxdy.top`（节点域名防环） |
| `fake-ip-filter-mode` | `blacklist`（默认）/ `whitelist` / `rule` | 未设（默认 blacklist） |
| `fake-ip-ttl` | fake-ip 查询 TTL | 未设（非必要勿改） |

> **fake-ip 原理**：DNS 请求进来，内核直接把域名映射到 `198.18.0.1/16` 的假 IP 返回；客户端连接假 IP 时，内核还原真实域名再按规则分流。客户端永远碰不到真实 IP，域名级分流/防泄漏/防污染由内核统一完成。

### 4.2 解析服务器分层

| 字段 | 官方语义 | MiniClash 值 |
|------|----------|-------------|
| `default-nameserver` | **bootstrap**：必须为 IP，解析 DNS 服务器自身域名 | `223.5.5.5`、`119.29.29.29` |
| `nameserver` | 默认解析服务器（主） | `https://1.1.1.1/dns-query#自动优选`、`https://8.8.8.8/dns-query#自动优选`（**国外 DoH 经代理**，不掉国内 DNS） |
| `nameserver-policy` | 指定域名走指定解析器（可用 geosite/rule-set），优先于 nameserver | `rule-set:cn` → 国内 DoH（doh.pub/alidns）直连；`+.lan`/`+.local` → 明文 |
| `proxy-server-nameserver` | **仅解析节点域名**，防节点域名被 fake-ip 化导致连节点死循环 | `223.5.5.5`、`119.29.29.29`（**必须直连**） |
| `fallback` | 后备解析服务器（旧防污染机制） | 未用（改用 nameserver + nameserver-policy 分流） |
| `direct-nameserver` | DIRECT 出口域名专用解析 | 未用 |
| `fallback-filter` | 判定"污染"的规则，命中则用 fallback 结果 | 未设（已不依赖 fallback） |

**MiniClash 国内外分流设计**：
1. **fake-ip**：客户端不碰真实 IP
2. **nameserver 经代理用国外 DoH**：海外域名不掉国内 DNS、防污染
3. **nameserver-policy 让国内域名（`rule-set:cn`）走国内 DoH 直连**：国内站拿到本地 CDN
4. **proxy-server-nameserver 用明文 IP 兜底**：节点域名必须直连拿到真实 IP（否则经代理解析节点域名会死循环）

> `rule-set:cn` 的域名集来自 `cn.mrs`（`rule-providers` 以 `type: file / format: mrs` 加载，无需联网下载 geosite.dat）。

**验证**：
```sh
nslookup github.com 127.0.0.1 -port=7874   # 应返回 198.18.x.x 假 IP
curl -s -H "Authorization: Bearer $(cat /etc/miniclash/api_secret)" \
  'http://127.0.0.1:9090/dns/query?name=github.com&type=A'   # 内核 DNS 查询
```

---

## 5. 规则分流（rules）

### 5.1 匹配规则

- **自上而下顺序匹配**，顶部优先级最高；全不中走最后的 `MATCH` 兜底
- UDP 请求若命中的节点不支持 UDP，会继续向下匹配

### 5.2 常用规则类型

| 类型 | 语义 | MiniClash 用到 |
|------|------|---------------|
| `DOMAIN,ad.com,REJECT` | 完整域名精确匹配 | — |
| `DOMAIN-SUFFIX,google.com,auto` | 域名后缀匹配（含主域名，不匹配 `content-google.com`） | ✅ 注入 Apple/微软/hf-mirror/sun-clan/prss.microsoft/delivery.mp.microsoft |
| `DOMAIN-KEYWORD,google,auto` | 域名关键字匹配 | ✅ 注入 `xiaohongshu`、`officecdn` |
| `DOMAIN-WILDCARD,*.google.com,auto` | 通配符（`*` 零或多、`?` 单个），与 fake-ip-filter 的通配符不同 | — |
| `DOMAIN-REGEX,^abc.*com,PROXY` | 域名正则 | — |
| `GEOSITE,youtube,PROXY` | geosite 集合匹配 | 订阅自带 |
| `IP-CIDR,127.0.0.0/8,DIRECT,no-resolve` | IP 网段匹配（`IP-CIDR6` 同义别名） | 订阅自带 |
| `IP-ASN,13335,DIRECT` | IP 所属 ASN | 判定出口看 ASN 的依据 |
| `GEOIP,CN,DIRECT` | IP 所属国家 | ✅ 订阅自带大陆直连 |
| `DST-PORT,80,DIRECT` / `SRC-PORT` | 目标/来源端口 | — |
| `SRC-GEOIP` / `SRC-IP-CIDR` | 来源 IP 匹配 | — |
| `IN-PORT/IN-TYPE/IN-USER/IN-NAME` | 按入站端口/类型/用户/名匹配 | — |
| `PROCESS-NAME/PATH*` | 按进程匹配（需 find-process-mode） | — |
| `NETWORK,udp,DIRECT` | 按协议匹配 | — |
| `RULE-SET,providername,proxy` | 引用规则集合（rule-providers） | rules 段未用；仅 DNS `nameserver-policy` 用 `rule-set:cn` 走国内 DoH |
| `AND/OR/NOT` | 逻辑组合规则，注意括号 | 未用 |
| `SUB-RULE` | 匹配到子规则继续分流 | 未用 |
| `MATCH,auto` | 匹配所有 | ✅ 订阅兜底 |

**`no-resolve` 参数**：IP 类规则（GEOIP/IP-CIDR/IP-ASN…）匹配域名时会触发 DNS 解析；加 `no-resolve` 跳过，减少解析。

### 5.3 MiniClash 的规则构成

1. **订阅 rules 原样直通**（订阅自带 proxy-groups 在本地过滤时已删除，组由 gen_config 统一生成）
2. **注入 EXTRA 规则**（在 `rules:` 最前，缩进取 rules 首元素对齐）：
   - `DOMAIN-SUFFIX,apple.com/icloud.com/microsoft.com/…,自动优选`（订阅 DIRECT 兜底但本网直连不通的海外服务）
   - `DOMAIN-KEYWORD,xiaohongshu,DIRECT`、`DOMAIN-SUFFIX,hf-mirror.com/sun-clan.com,DIRECT`、`DOMAIN-SUFFIX,prss.microsoft.com/delivery.mp.microsoft.com,DIRECT`（国内可直连却会被兜进代理的；后两个须排在 `microsoft.com` 之前）
3. **订阅默认组引用改指「自动优选」**（`BoostNet`/`🔰国外流量`/`⚓️其他流量` → 自动优选）

**验证**：
```sh
curl -s -H "Authorization: Bearer $(cat /etc/miniclash/api_secret)" http://127.0.0.1:9090/rules
# 每条的 hitCount / hitAt 可看规则命中情况，定位"某域名走了哪条规则"
```

---

## 6. REST API（external-controller）

认证：每个请求带 `Authorization: Bearer ${secret}`。

### 6.1 策略组与代理

| 端点 | 方法 | 说明 | MiniClash 用 |
|------|------|------|-------------|
| `/proxies` | GET | 全部代理/组，策略组含 `now`/`all`/`type`/`fixed`/`history` | watchdog 查 |
| `/proxies/自动优选` | GET | 单组：`now` 当前选中、`type`、`all` 成员 | ✅ |
| `/proxies/<name>` | PUT | 手动切换（主组传国家组名 `{"name":"新加坡组"}`） | judge 裁决 / 调试用 |
| `/proxies/<name>` | DELETE | 清除 url-test/fallback 的 fixed 固定选择 | — |
| `/proxies/<name>/delay` | GET | 单点测速：`?url=xxx&timeout=5000&expected=200/204` | 测节点 |
| `/group/<name>/delay` | GET | 组内全部成员测速 | 调试 |

### 6.2 运行控制

| 端点 | 方法 | 说明 |
|------|------|------|
| `/configs` | GET/PATCH/PUT | 读配置 / 热改字段（如 `{"mixed-port":7890}`）/ 重载（`?force=true`） |
| `/restart` | POST | 重启内核 |
| `/upgrade` `/upgrade/geo` `/upgrade/ui` | POST | 更新内核 / GEO / 面板 |
| `/cache/fakeip/flush` `/cache/dns/flush` | POST | 清 fake-ip / DNS 缓存 |
| `/connections` | GET/WS/DELETE | 实时连接（含命中规则、链路），可关单个/全部 |
| `/rules` | GET | 规则列表含命中计数，可 PATCH `/rules/disable` 临时禁规则 |
| `/traffic` `/memory` `/version` | GET/WS | 速率 / 内存 / 版本 |
| `/dns/query` | GET | 内核 DNS 查询（`?name=&type=`） |
| `/logs` | GET/WS | 实时日志（`?level=debug` 需内核 debug 启动） |
| `/debug/pprof` | GET | Go 性能分析（需 debug 日志级别） |

**watchdog 的用法**（每 `check_interval` 秒一次）：
```sh
# 读主组当前国家；now 是国家组名，再展开一层取实际节点
GET /proxies/自动优选   → now=新加坡组
GET /proxies/新加坡组  → 组内实际选中
```

---

## 7. 代理协议（proxies）与 TLS 指纹

### 7.1 anytls（MiniClash 机场协议）

官方要点（`docs/config/proxies/anytls.md`）：
- 核心字段：`server`/`port`/`password`/`client-fingerprint`/`udp`/`sni`/`alpn`/`skip-cert-verify`
- **不支持 anytls+Reality 组合**；要隐藏 SNI 配合 ECH 或 ShadowTLS/ResTLS/JLS
- `client-metadata`：v1.19.30 起默认不再发送（可能被用于统计），需用自填
- 空闲会话：`idle-session-check-interval` / `idle-session-timeout` 默认 30s

### 7.2 client-fingerprint（TLS 指纹）

**官方语义**：客户端 utls 指纹，仅适用于 VMess/VLESS/Trojan/AnyTLS。可选：`chrome`/`firefox`/`safari`/`ios`/`android`/`edge`/`360`/`qq`/`random`。

**MiniClash 注入规则**（`gen_config` 的 awk）：proxies 段里**无 `client-fingerprint` 的 flow 节点统一补 `firefox`**（跳过已有指纹）。

**为什么**：mihomo 默认指纹的 ClientHello 达 1510B，超过 TCP MSS(1452)；路由器 GSO/TSO 合并大包被中间设备丢前段 → TLS 握手永不完整 → 全部节点 `i/o timeout`。firefox 指纹包小单段不分片，握手正常。完整因果见 [事故报告](incident-2026-09-01-boostnet-dial-failure.md)。

**验证**：
```sh
grep -A2 '日本1' /etc/miniclash/config.yaml | head -5   # 应含 client-fingerprint: firefox
```

---

## 8. 健康检查与自动选优时间参数

| 参数 | 官方语义 | MiniClash 值 | 为什么 |
|------|----------|-------------|--------|
| `url` | 健康检查测试地址 | `github.com/generate_204` | 与真实场景一致；不用订阅的 gstatic（判死日本） |
| `interval` | 检查间隔（秒），url-test 适用 | `60` | 官方默认 300，机场劣化分钟级，60 已够积极 |
| `tolerance` | url-test 切换容差（ms） | `200` | 同国节点延迟接近（真值差 34ms）且单次采样噪声大（跨度 546ms），200 是「识别真劣化」与「不被噪声带偏」之间的有效门槛（2026-10-24 实测） |
| `expected-status` | 期望响应码，默认 `*` 任意都算通 | `200/204` | 只认真实 204，防劫持假 200 误判健康 |
| `timeout` | 检查超时（ms），默认 5000 | 未设 | 默认够用 |
| `max-failed-times` | 超过则强制健康检查，默认 5 | 未设 | 默认即可 |
| `lazy` | 未选中不测速，默认 true | 未设 | 全屋常流量，省不了多少 |

**关键行为**：url-test 当前节点超时即**立即触发测速切换**（不等整个 interval），tolerance 决定"领先多少才切"。**切换会断连**（在途连接重建），所以组内 200ms 门槛、国家由 judge 双确认 + 20% margin 裁决，是"慢半拍但稳"的定调设计。

---

## 9. 未用到的扩展能力（简提）

MiniClash 保持极简，这些 mihomo 能力未启用，将来可按需打开：

| 能力 | 官方入口 | 用途 |
|------|----------|------|
| TUN 模式 | `tun.enable` + `auto-route` | 免 iptables 的全端透明代理（含 UDP/本机） |
| UDP 透明代理 | `tproxy-port` + TPROXY 规则 | 游戏/QUIC 等 UDP 流量 |
| 逻辑规则 | `AND/OR/NOT/SUB-RULE` | 复杂分流场景 |
| 规则集合 | `rule-providers` + `RULE-SET` | 订阅独立维护规则集，热更新 |
| 代理集合 | `proxy-providers` + `use` | 多订阅节点池动态拉取 |
| 负载均衡 | `load-balance`（consistent-hashing/sticky） | 多线路带宽聚合 |
| 面板 | `external-ui` + `/ui` | 可视化看节点/规则/连接 |
| 热重载 | `/configs` PATCH | 运行时改端口/mode 等，免重启 |

---

## 10. 快速验证命令集

```sh
# 状态与配置
/etc/init.d/miniclash status
cat /etc/miniclash/config.yaml                       # 看注入的组/规则/指纹

# API（需要 secret）
S="Authorization: Bearer $(cat /etc/miniclash/api_secret)"

# 自动优选当前国家
curl -s -H "$S" http://127.0.0.1:9090/proxies/自动优选 | grep -oE '"(now|type)":"[^"]*"'
# 国家组实际选中（再展开一层）
curl -s -H "$S" http://127.0.0.1:9090/proxies/新加坡组 | grep -oE '"now":"[^"]*"'

# 单点测速（expected 只认真实 204）
curl -s -H "$S" 'http://127.0.0.1:9090/proxies/日本1/delay?url=https://github.com/generate_204&timeout=5000&expected=200/204'

# 连通性实测（本机不走劫持，必须 -x 走 mixed 口）
curl -x http://127.0.0.1:7893 -s -o /dev/null -w 'HTTP %{http_code} (%{time_total}s)\n' https://github.com
curl -x http://127.0.0.1:7893 -s -o /dev/null -w 'HTTP %{http_code}\n' https://www.gstatic.com/generate_204

# 规则命中 / fake-ip 检查
curl -s -H "$S" http://127.0.0.1:9090/rules | grep -E 'hitCount' | head
nslookup github.com 127.0.0.1 -port=7874
```

---

**依据**：mihomo 官方文档 [meta-docs](https://github.com/metacubex/meta-docs)（docs/config 的 general/inbound/proxy-groups/dns/rules/proxies、docs/handbook、docs/api，2026-09 版）。MiniClash 当前部署的 `config.yaml` 为最终事实来源。
