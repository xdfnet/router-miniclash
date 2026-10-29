# 域名干预清单

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
| `prss.microsoft.com` | VSCode 等下载 CDN，国内可直连 | 必须排在 `microsoft.com` 之前（后者走代理） |
| `delivery.mp.microsoft.com` | Edge 下载 CDN，国内联通节点 | 直连 0.18s vs 代理 0.40s |
| `hf-mirror.com` | HuggingFace 镜像站，解析到东京 SAKURA，国内可直连 | — |
| `xiaohongshu.com`（关键字 `xiaohongshu`） | 小红书，国内服务 | 注意：桌面端会连自己的本地服务 `localhost.redpass.xiaohongshu.com:10001-10011`，命中 DIRECT 后连 127.0.0.1 被拒 → 日志里每天上千条 `connection refused`，**是噪音不是故障** |
| `sun-clan.com` | 国内服务 | — |

### 强制走代理（订阅把国内可直连的兜成 DIRECT，但实际直连不通）

| 域名 | 原因 |
|---|---|
| `apple.com` / `icloud.com` | 订阅默认把 Apple 系兜成 DIRECT，但本网络直连 Apple 超时（Apple 在国内无 CDN 落点） |
| `microsoft.com` / `microsoftonline.com` / `office.com` / `office365.com` / `live.com` / `officecdn`（关键字） | 微软账号、OneDrive、Office 登录与更新直连不通 |

---

## 二、DNS 层的干预（不是 rules，但也属于"干预"）

| 位置 | 做什么 | 为什么 |
|---|---|---|
| `dns.direct-nameserver` | DIRECT 命中的域名用国内 DNS（223.5.5.5 / 119.29.29.29）解析 | 默认跟随 `nameserver`（国外 DoH 经节点），会把 `dl.google.com` 解析到 **142.251.x 境外 IP**，直连必然超时（2026-10-29 实测）。国内 DNS 给的是 120.253.x 国内 CDN 节点 |
| `dns.nameserver-policy` 的 `rule-set:cn` | 国内域名用国内 DoH 直连解析 | 不给国内域名套国外 DoH |
| `dns.fake-ip-filter` | `+.lan` / `+.local` / `+.myzxdy.top` 不 fake-ip | 内网域名给真 IP |
| `dns.proxy-server-nameserver` | 节点服务器域名用真实 DNS | 避免 fake-ip 化导致内核解析节点时死循环 |
| dnsmasq drop-in 的 `host-record=localhost.weixin.qq.com,127.0.0.1` | 微信桌面端的本地服务固定答 127.0.0.1 | 走 fake-ip 会把流量劫到路由器，路由器连自己的 127.0.0.1 → `connection refused`（2026-10-26 实测每天 440 次） |

---

## 三、新增/删除一条规则的流程

1. **先量，别猜**。在路由器上取真实 IP，直连实测与走代理实测对比：

   ```sh
   # 路由器本机出站不被劫持，用真实 IP 直连才是有效判据
   ip=$(nslookup "$d" 223.5.5.5 2>/dev/null | grep -oE "Address [0-9]+: [0-9.]+" | tail -1 | cut -d" " -f3)
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

## 四、已否决的干预（别再加回去）

- **`gdtimg.com` DIRECT**：加了仍 2.5s，腾讯广告走的是境外 CDN 节点，规则无效，已回滚。
- **`dl.google.com` 走代理**：能通但 100KB/s，266MB 要 40 分钟，Updater 必然超时——已改 DIRECT。
- **Apple/微软系改回 DIRECT**：本网络直连超时，改了等于断登录。
