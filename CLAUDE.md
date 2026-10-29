# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目是什么

MiniClash 是部署在 OpenWrt 路由器上的**无界面全屋透明代理**：mihomo 内核 + 单 init.d 脚本 + 4 个 UCI 字段。仓库本身不运行，所有产物经 `ssh luyou`（`192.168.100.1`，别名已在本机 `~/.ssh/config`，勿手指定用户/密钥）部署到路由器；Mac 只跑 `scripts/` 下的控制脚本。无构建、无测试、无 lint——Shell + YAML/UCI 配置项目，验证靠真机访问与 `mihomo -t`。

## 常用命令

在 Mac（仓库根）执行：

```bash
./scripts/install.sh             # 一键部署 root/ → 路由器（缺内核/GeoIP 自动下载；不覆盖已有 UCI；末尾自动拉订阅+重启）
./scripts/update-subscribe.sh    # 拉订阅 → base64 检测 → 过滤日/新节点 → 上传 → restart（最常用的日常操作）
./scripts/update-kernel.sh       # 下载内核+GeoIP 到 root/；--deploy 同步路由器并重启
./scripts/traffic.sh              # 查套餐剩余流量/重置/到期（信息条目藏在订阅 proxies 段）
./scripts/inspect.sh             # 巡检一键取数（9 项巡检，清单与汇报格式见 docs/inspection.md）
./scripts/diagnose.sh             # TypeSafe Jev 智能分诊日志（需 TYPESAFE_API_KEY、jq；日志自动脱敏后出网）
./scripts/uninstall.sh            # 彻底卸载（交互确认）
./scripts/start-proxy.sh          # = ssh luyou '/etc/init.d/miniclash start'（stop 同理）
```

在路由器上：

```bash
/etc/init.d/miniclash {start|stop|restart|status}
uci get miniclash.core.node                 # 当前实际节点（watchdog 每 60s 上报）
tail /etc/miniclash/judge.log               # judge 裁决历史（每轮一行，含"保持"）
tail /etc/miniclash/guard.log               # 故障自愈记录（当前节点不通 → 切备用）
head /tmp/miniclash_rank                    # 带宽排名（judge 写，guard 按序找备选）
mihomo -t -d /etc/miniclash -f /etc/miniclash/config.yaml   # 改完配置必跑的真实试读校验
```

改 UCI 配置后：`uci commit miniclash && /etc/init.d/miniclash restart`。

## 架构（需跨文件理解的大图景）

**双平面**：数据面（LAN TCP 被 iptables REDIRECT 到 7892、DNS 被 dnsmasq 指向 fake-ip 7874）运行期无脚本干预；控制面全部逻辑在 [root/etc/init.d/miniclash](root/etc/init.d/miniclash)（319 行，单文件）。

**配置生成 `gen_config()`**（init.d 内，核心中的核心）：
- 端口/DNS/API 头部由脚本写死；上传的订阅 `subscribe.yaml` 从 `proxies:` 起 awk 直通内核，订阅自带的 port/dns/proxy-groups 段被丢弃或删除。
- 把订阅的全部节点直接挂进 select 主组「自动优选」（**单池，没有国家 url-test 组**）；rules 里 `,BoostNet`/`,🔰国外流量`/`,⚓️其他流量` 引用统一改写为 `,自动优选`。
- 在 rules 顶部注入例外（Apple/微软走代理、hf-mirror/小红书/sun-clan/boost1.shop/dl.google.com/vsassets.io 强制直连）；**每条规则的原因与实测数据记在 [docs/domain-rules.md](docs/domain-rules.md)**，改规则先读它。对无指纹的 flow 节点注入 `client-fingerprint: firefox`。

**单池择优（2026-10-29 起，取代原来的"组内核 url-test + 跨国 judge"两层）**：
1. 择优：[judge.sh](root/usr/share/miniclash/judge.sh)（cron 每 15 分钟）以**真实下载带宽**为判据——[probe.sh](root/usr/share/miniclash/probe.sh) 经 config.yaml 的 `listeners` 段（每个节点一个钉死的本地端口）**串行**实测 1MB 下载速度，节点分取最近 4 次中位数；连续 2 次同一候选领先 25% 才经 API（9090，secret 在 `/etc/miniclash/api_secret`）PUT 切换。当前节点带宽掉到最优的 1/3 以下时**单轮即切**（快速通道，慢节点不等 30 分钟）。
2. 自愈：[guard.sh](root/usr/share/miniclash/guard.sh) 用 mihomo delay API 探活当前节点，不通就按 judge 写的 `/tmp/miniclash_rank` 从前往后找第一个活的 PUT 过去（实测 2 秒）。watchdog 每 60s 调一次，judge 每轮开头也调一次兜底。**没有 url-test 组后内核不再维护 alive，探活必须自己做。**
3. 开机/重启时 init.d 以 `BOOT=1` 前台跑一次 judge（测全部 16 个节点，约 5 分钟），绕过防抖直选最优节点。
4. 为什么不用内核 url-test：它按延迟选，实测它选中的恰是组内带宽最差的节点（2026-10-29：新加坡1 到 dl.google.com 111KB/s，同批新加坡7 829KB/s）。详见 [docs/pool-selection.md](docs/pool-selection.md)。

**订阅本地过滤**：路由器不保存订阅地址（`subscription.url` 只在 Mac）。[update-subscribe.sh](scripts/update-subscribe.sh) 过滤后**强校验必须为 16 个日/新节点**，不符即拒绝上传。

## 修改时的高风险点

- **节点名归集只有一处**：init.d `gen_config()` 与 judge.sh 都从订阅的 `proxies:` 段按 `name:` 取全部节点（同一段 awk）。改节点过滤规则要同时看这两处。
- **测速底座耦合点**：init.d 生成的 `listeners` 段（每节点一个 pinned 端口，9100 起）是 probe.sh 测带宽的唯一入口——改了节点归集规则或端口起点，两边必须同步，否则 probe 静默测不到（节点分变 0）。测速**必须串行**，并发会互抢带宽毁掉排序。
- **人工域名干预集中在 `gen_config()` 的 EXTRA 块**：改那里的规则必须同步更新 [docs/domain-rules.md](docs/domain-rules.md)（原因 + 实测数据），否则文档与代码不同源。
- **YAML 注入缩进逐字节一致**：注入的规则/组行缩进由 awk 取 `rules:` 首元素缩进动态对齐（旧订阅 4 空格、新订阅 2 空格）。缩进错位会吞掉后续所有规则，表现为 `proxy [自动优选...] not found`。
- **iptables 只劫持 PREROUTING**（LAN 转发），绝不劫持本机出站——否则内核连节点被重定向回自己形成自环（`context deadline exceeded`）。
- 内核（~55M）与 Country.mmdb（~8M）**不入库**（.gitignore），本地缺失时 install.sh 自动调 update-kernel.sh；本地版本靠 `.mihomo-version` 标记对比（Mac 无法运行 linux 二进制）。
- 启动序列里的 wait_wan、MMDB 在位检查 + 备份恢复、关 WAN GSO/TSO 均有真实事故教训（见 docs/），不要当冗余删除。
- 路由器是 BusyBox/Dropbear 环境：`ps` 不支持 `aux`；脚本面向 POSIX sh + awk/sed/grep，不要引入 bash 数组/GNU 特性（Mac 端脚本除外，它们是 `#!/bin/bash`）。

## 文档与发布

文档即设计：改动行为前先读 [README.md](README.md)（含排障速查）与 [docs/architecture.md](docs/architecture.md)，各机制下的注释里写明了事故根因（2026-08-18 打地鼠、09-01 TLS 指纹超 MSS、09-21 整国劣化等）。**发布前先更新文档，commit 必须包含文档变更**。
