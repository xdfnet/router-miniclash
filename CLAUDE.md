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
mihomo -t -d /etc/miniclash -f /etc/miniclash/config.yaml   # 改完配置必跑的真实试读校验
```

改 UCI 配置后：`uci commit miniclash && /etc/init.d/miniclash restart`。

## 架构（需跨文件理解的大图景）

**双平面**：数据面（LAN TCP 被 iptables REDIRECT 到 7892、DNS 被 dnsmasq 指向 fake-ip 7874）运行期无脚本干预；控制面全部逻辑在 [root/etc/init.d/miniclash](root/etc/init.d/miniclash)（319 行，单文件）。

**配置生成 `gen_config()`**（init.d 内，核心中的核心）：
- 端口/DNS/API 头部由脚本写死；上传的订阅 `subscribe.yaml` 从 `proxies:` 起 awk 直通内核，订阅自带的 port/dns/proxy-groups 段被丢弃或删除。
- 按节点名前缀（`日本`/`新加坡`）归集，在 `rules:` 前生成 select 主组「自动优选」+ 每国一个 url-test 国家组；rules 里 `,BoostNet`/`,🔰国外流量`/`,⚓️其他流量` 引用统一改写为 `,自动优选`。
- 在 rules 顶部注入例外（Apple/微软走代理、hf-mirror/小红书/sun-clan 强制直连）；对无指纹的 flow 节点注入 `client-fingerprint: firefox`。

**两层选优，互不干扰**：
1. 组内：mihomo 内核 url-test 每 60s 测 GitHub，tolerance 500ms 防抖，单节点故障秒级自愈。
2. 跨国：[judge.sh](root/usr/share/miniclash/judge.sh)（cron 每 5 分钟）对每节点实测 GitHub 主站 + githubassets(Fastly) 两地址、延迟相加打分，连续 2 次别国领先且当前国慢 20% 才经 API（9090，secret 在 `/etc/miniclash/api_secret`）PUT 切换。watchdog 只两层展开（select→国家组→节点）上报 `node`，**不驱动切换**。
3. 开机/重启时 init.d 以 `BOOT=1` 前台跑一次 judge，绕过防抖直选最优国（约 6s）。

**订阅本地过滤**：路由器不保存订阅地址（`subscription.url` 只在 Mac）。[update-subscribe.sh](scripts/update-subscribe.sh) 过滤后**强校验必须为 16 个日/新节点**，不符即拒绝上传。

## 修改时的高风险点

- **国家清单有两处，必须同步**：init.d `gen_config()` 和 judge.sh 里各自硬编码 `countries=日本,新加坡`（顺序第一国为 select 默认）。节点归集前缀规则也两处重复。
- **YAML 注入缩进逐字节一致**：注入的规则/组行缩进由 awk 取 `rules:` 首元素缩进动态对齐（旧订阅 4 空格、新订阅 2 空格）。缩进错位会吞掉后续所有规则，表现为 `proxy [自动优选...] not found`。
- **iptables 只劫持 PREROUTING**（LAN 转发），绝不劫持本机出站——否则内核连节点被重定向回自己形成自环（`context deadline exceeded`）。
- 内核（~55M）与 Country.mmdb（~8M）**不入库**（.gitignore），本地缺失时 install.sh 自动调 update-kernel.sh；本地版本靠 `.mihomo-version` 标记对比（Mac 无法运行 linux 二进制）。
- 启动序列里的 wait_wan、MMDB 在位检查 + 备份恢复、关 WAN GSO/TSO 均有真实事故教训（见 docs/），不要当冗余删除。
- 路由器是 BusyBox/Dropbear 环境：`ps` 不支持 `aux`；脚本面向 POSIX sh + awk/sed/grep，不要引入 bash 数组/GNU 特性（Mac 端脚本除外，它们是 `#!/bin/bash`）。

## 文档与发布

文档即设计：改动行为前先读 [README.md](README.md)（含排障速查）与 [docs/architecture.md](docs/architecture.md)，各机制下的注释里写明了事故根因（2026-08-18 打地鼠、09-01 TLS 指纹超 MSS、09-21 整国劣化等）。**发布前先更新文档，commit 必须包含文档变更**。
