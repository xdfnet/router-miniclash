# 域名干预清单

## 干预是为了什么

**不是"多分流"，是让每个域名走当前网络下真正对的那条路，并且随环境变化持续修正。**

1. **可用性**——订阅和 GEOIP 会替我们做决定，但它们的答案在某些域名上已经过时：
   Apple / 微软被兜成 DIRECT，而本网络直连超时 → 强制代理，否则登录与推送直接断。
2. **性能与成本**——同样的服务，国内 CDN 直连能快 10~100 倍：
   Chrome 更新包走代理 0.1MB/s 要 46 分钟，走国内 CDN 直连 13MB/s 只需 20 秒；
   同时少吃机场配额（剩余 140GB / 15 天）。
3. **抗复发**——**规则是有保质期的资产，不是写一次就完**。CDN 会换边缘节点、运营商策略会变、
   机场节点质量会浮动：今天对的规则明天可能有害（`vsassets.io` 当天加、当天撤，
   两轮实测结论正好相反）。所以干预必须**有进有出**：每次巡检既看要不要新增，也看已有的该不该撤。

反过来说，干预**不是**为了让规则列表变长，也不是凭"直觉上该直连"就写一条。
判据只有实测（真实文件、真实路径、多轮取样）；结论只有一条铁律：
**没带来提速就是没收益**。复核出的 ⚠ 是**线索不是判决**，要改规则得先用真实业务流量再验一次。

---

> 这份文档是**所有人工干预的域名规则的唯一记录**：走哪条、为什么、实测多少、什么时候加的。
> 规则本体写在 `root/etc/init.d/miniclash` 的 `gen_config()` 里（`EXTRA` 块，注入到 `rules:` 顶部），
> 改代码时**同一次提交里改本文**（文档与代码同源）。
>
> 为什么单独立档：这些规则每条都是"某个域名的真实情况"——CDN 位置变了、运营商策略变了、
> 某个域名被墙了——不看原因就改，等于把踩过的坑重新踩一遍。每条必须写清**实测数据**。

---

## 一、规则本体（`gen_config()` 的 EXTRA 块）

注入位置：`rules:` 段最前面。**顺序有意义**——先命中先生效，
所以更具体的域名必须排在更宽的域名之前（如 `prss.microsoft.com` 在 `microsoft.com` 之前）。

### 强制 DIRECT（国内可直连，不该走代理）

| 域名 | 原因 | 实测 |
|---|---|---|
| `boost1.shop` | 机场自己的订阅服务器。部分出口节点到它被**丢弃式封锁**（连上不回数据），换到被封锁的节点就拉不到订阅、查不了流量 | 2026-10-27：日本1/3/4/8 走代理 10s 无响应；8 个新加坡节点与直连都 200；直连 0.8s |
| `dl.google.com` | Chrome 全平台更新包 266MB。该域名解析到**中国移动 CDN**（120.253.x），国内直连极快；走代理是绕地球 | 2026-10-29：路由器直连 4.6MB/s vs 走代理 0.1MB/s（差 30 倍），走代理必超时 |
| `vsassets.io` | VS Code 扩展资产 CDN，Akamai 国内节点（23.49.x / 23.200.x） | 2026-10-29：根路径直连 0.26s vs 代理 0.30~1.5s；同族 `marketplace.visualstudio.com` 真实 .vsix 包直连 575KB/s vs 代理 52KB/s（11 倍） |
| `prss.microsoft.com` | VSCode 等下载 CDN，国内可直连 | 必须排在 `microsoft.com` 之前（后者走代理）。注意实测直连 438KB/s vs 代理 441KB/s——**这条目前零收益也无害**（瓶颈在 CDN 本身不在路由），留着是挡整族 microsoft.com 走代理 |
| `delivery.mp.microsoft.com` | Edge 下载 CDN，国内联通节点 | 直连 0.18s vs 代理 0.40s |
| `hf-mirror.com` | HuggingFace 镜像站，解析到东京 SAKURA，国内可直连 | — |
| `xiaohongshu.com`（关键字 `xiaohongshu`） | 小红书，国内服务 | 注意：桌面端会连自己的本地服务 `localhost.redpass.xiaohongshu.com:10001-10011`，命中 DIRECT 后连 127.0.0.1 被拒 → 日志里每天上千条 `connection refused`，**是噪音不是故障** |
| `sun-clan.com` | 国内服务 | — |
| `ls.apple.com` | **地图瓦片与地理配置**（`gspe*-cn-ssl.ls.apple.com`）。Apple 在国内有 CDN 落点（阿里/移动 CDN），但被下面的 `apple.com` 兜底规则一起塞进代理节点 → macOS 地图与「查找」里的地图绕地球取瓦片 | 2026-10-29：Mac 侧实测 `gspe19-cn` 代理 2.5~3.4s → 直连 **0.12s**；`gspe19-2-cn` 代理 1.8~6.1s → 直连 **0.07s**；`gspe35-ssl` → 0.07s。改后 mihomo 连接表确认命中 `DIRECT` |
| `apple-mapkit.com` | MapKit CDN（`cdn.apple-mapkit.com`），同上 | 2026-10-29：代理 0.43~0.85s → 直连 **0.08s** |

### 强制走代理（订阅把国内可直连的兜成 DIRECT，但实际直连不通）

| 域名 | 原因 |
|---|---|
| `apple.com` / `icloud.com` | 订阅默认把 Apple 系兜成 DIRECT，但本网络直连 Apple 超时（Apple 在国内无 CDN 落点）。**例外**：地图基础设施（`ls.apple.com` / `apple-mapkit.com`）走 DIRECT，见上表 |
| `microsoft.com` / `microsoftonline.com` / `office.com` / `office365.com` / `live.com` / `officecdn`（关键字） | 微软账号、OneDrive、Office 登录与更新直连不通 |

---

## 二、DNS 层的干预（不是 rules，但也属于"干预"）

| 位置 | 做什么 | 为什么 |
|---|---|---|
| `dns.direct-nameserver` | DIRECT 命中的域名用国内 DNS（223.5.5.5 / 119.29.29.29）解析 | 默认跟随 `nameserver`（国外 DoH 经节点），会把 `dl.google.com` 解析到 **142.251.x 境外 IP**，直连必然超时（2026-10-29 实测）。国内 DNS 给的是 120.253.x 国内 CDN 节点。同样保证 `ls.apple.com` 落到 Apple 的国内 CDN（阿里/移动）而非境外边缘 |
| `dns.nameserver-policy` 的 `rule-set:cn` | 国内域名用国内 DoH 直连解析 | 不给国内域名套国外 DoH |
| `dns.fake-ip-filter` | `+.lan` / `+.local` / `+.myzxdy.top` 不 fake-ip | 内网域名给真 IP |
| `dns.proxy-server-nameserver` | 节点服务器域名用真实 DNS | 避免 fake-ip 化导致内核解析节点时死循环 |
| dnsmasq drop-in 的 `host-record=localhost.weixin.qq.com,127.0.0.1` | 微信桌面端的本地服务固定答 127.0.0.1 | 走 fake-ip 会把流量劫到路由器，路由器连自己的 127.0.0.1 → `connection refused`（2026-10-26 实测每天 440 次） |

---

## 三、新增/删除一条规则的流程

> 候选从哪来：**每次巡检的第 9 项自动跑** `./scripts/domain-candidates.sh`——
> 它把"兜底走代理"的域名逐个与直连对照，输出判定。
> 已在本文件记录为"必须代理"的域名会自动跳过，所以每次巡检只看新面孔。

1. **先量，别猜**。在路由器上取真实 IP，直连实测与走代理实测对比：

   ```sh
   # 路由器本机出站不被劫持，用真实 IP 直连才是有效判据
   ip=$(nslookup "$d" 223.5.5.5 2>/dev/null | grep -oE "Address [0-9]+: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | tail -1 | cut -d" " -f3)
   curl -sk -o /dev/null -w "%{http_code} %{time_total}s\n" --max-time 8 --resolve "$d:443:$ip" "https://$d/"
   ```

2. **判据**：真实 IP 属国内段且直连明显快于代理 → 加 DIRECT；直连不通或更慢 → 保持代理；
   属已知有意设计（Apple 全家、微软账号域）→ 不动。

3. **写规则**：`gen_config()` 的 `EXTRA` 块，位置按"更具体的在前"排。

4. **写文档**：本文加一行，带上原因和实测数字。

5. **部署验证**：`mihomo -t` 通过再 restart，然后**复测**：

   - 目标域名的实测速度（规则生效的证据）
   - 其余路径无回归（加规则最容易伤到别人——本文里 `prss.microsoft.com` 排错顺序、
     `dl.google.com` 改 DNS 两处都踩过坑）
   - **没带来提速就是没收益，回滚**（真实案例：`gdtimg.com` 加 DIRECT 后仍 2.5s，
     因为腾讯广告用的是境外 CDN 节点）

---

## 四、复核：已加的规则还该留着吗

复核脚本：`./scripts/domain-review.sh`（巡检第 9 项自动跑）。判据与坑见
[inspection.md 第 9b 项](inspection.md)。

**表是一张，不要每轮追加**——复核出新的 ⚠ 就更新对应行的"结论"列，
新域名另起一行；只有结论变化时才改"首次复核"。

| 规则 | 首次复核 | 结论 |
|---|---|---|
| `boost1.shop`（DIRECT） | 直连正常 | 保持 |
| `dl.google.com`（DIRECT） | 直连正常 | 保持（Chrome 更新 13MB/s） |
| `prss.microsoft.com`（DIRECT） | 直连正常 | 保持（当前零收益也无害，挡整族 microsoft.com） |
| `delivery.mp.microsoft.com`（DIRECT） | ⚠ 根路径直连 000 | **维持 DIRECT**：根路径 000 是 CDN 不给根路径；真实 Edge 包实测代理路径 404（根本下不到）、直连 1.37MB/s 正常 |
| `apple.com`/`icloud.com`/`microsoft.com`/`microsoftonline.com`/`office.com`/`office365.com`/`live.com`/`officecdn`（PROXY） | ⚠ 部分报"直连快 1.6~1.7 倍" | **维持代理**：根路径（302/403/400）不是真实业务路径，1.6 倍又贴着门槛（实测噪声本身就能到 1.5~1.7 倍）；微软系直连不通是当初加规则的原因 |
| `hf-mirror.com`/`xiaohongshu`/`sun-clan.com`（DIRECT） | 直连正常 | 保持 |
| `ls.apple.com`/`apple-mapkit.com`（DIRECT） | 直连正常（2026-10-29 改后实测 0.07~0.12s） | 保持（地图瓦片不再绕地球） |

> ⚠ 只用来**挑出要人工细看的那几条**，不作为直接改规则的依据——
> 这是铁律「没带来提速就是没收益」在撤销方向上的落法。

## 五、已否决的干预（别再加回去）

- **`gdtimg.com` DIRECT**：加了仍 2.5s，腾讯广告走的是境外 CDN 节点，规则无效，已回滚。
- **`dl.google.com` 走代理**：能通但 100KB/s，266MB 要 40 分钟，Updater 必然超时——已改 DIRECT。
- **Apple/微软系改回 DIRECT**：本网络直连超时，改了等于断登录。
- **`vsassets.io` DIRECT**（2026-10-29 当天加了又撤）：**同一天测两轮，结论完全相反**——
  第一轮"直连快 11 倍"（marketplace.visualstudio.com 的 .vsix 直连 575KB/s vs 代理 52KB/s），
  几小时后用 vsassets.io 自己的真实 .vsix 包复测：**直连 26KB/s vs 代理 3.18MB/s，代理快 120 倍**。
  原因是 Akamai 的国内边缘节点分配极不稳定（先后落到 23.49.x / 23.200.x / 23.209.73.52，
  快的慢的差 100 倍）。**教训：CDN 类域名的"直连更快"必须用真实文件测、且隔一段时间复测，
  否则加进去的是一条随机生效的规则。**

### 2026-10-29 兜底代理域名实测（7 天数据，共 ~1.7GB 走代理）

巡检第 5 项的"兜底走代理"桶就是候选来源。逐个实测直连（路由器本机 + 国内 DNS 真实 IP）
与代理的差异，结论如下：

| 域名 | 7 天代理量 | 直连实测 | 代理实测 | 判定 |
|---|---|---|---|---|
| `release-assets.githubusercontent.com` | 1050 MB | 185.199.108.133 超时 | 通 | **必须代理**（GitHub 出口直连不通） |
| `downloads.claude.ai` | 365 MB | 35.190.46.17 超时 | 通 | **必须代理** |
| `res.public.onecdn.static.microsoft` | 103 MB | 104.18.18.203 0.77s | 0.67s | 不干预（代理还略快） |
| `claude.ai` | 54 MB | — | 通 | **必须代理** |
| `cdn.nuphy.io` | 33 MB | 163.181.77.216（阿里云 CDN）1.50s | 1.69s | 边际收益（省 0.2s），未加 |
| `szxiaozi.com` | 17 MB | 119.28.67.219（腾讯云）连接被重置 | 通 | 直连不通，保持代理 |
| `swiftlang.gallerycdn.vsassets.io` | 12 MB | 23.49.104.53（Akamai）0.26~0.29s | 0.30~1.5s | **已加 `vsassets.io` DIRECT**（2026-10-29；同族 .vsix 真实包直连快 11 倍） |
| `imagine-public.x.ai` | 4 MB | 157.240.8.50 超时 | 0.75s | **必须代理** |

结论：这批里真正值得干预的只有 `dl.google.com`（100 倍差距，已加），
`vsassets.io` 次之（同族真实包 11 倍，已加）；
`cdn.nuphy.io` 与 `res.public.onecdn.static.microsoft` 收益都在百毫秒级、周流量几十 MB，
按"没带来提速就是没收益"的判据**不写规则**。

> 这些结论不是一次性的：`scripts/domain-candidates.sh`（巡检第 9 项）每次巡检都会重跑，
> 新域名会自己冒出来。本节记录的是已处理过的，脚本会跳过已判定"必须代理"的那些。

> 另测：`prss.microsoft.com`（已注入 DIRECT）实测直连 438KB/s vs 代理 441KB/s——
> 瓶颈在 CDN 本身而非路由，**这条规则目前零收益也无害**。留着不删（它挡的是"整族 microsoft.com
> 走代理"的大网段，撤了反而可能被兜进代理）。
