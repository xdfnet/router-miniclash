# 巡检清单与汇报方案

手动巡检的标准流程。每个项目有固定判据，命中异常才需要动作；全部正常时
不需要逐项汇报（见文末汇报模板）。

一条命令跑完全部取数：`./scripts/inspect.sh`（自动执行 1~8 项并输出结构化结果，
第 9 项需人工判读）。

---

## 巡检项目

### 1. 服务存活
- **取数**：`/etc/init.d/miniclash status`；`/proc/<pid>/stat` 算启动时刻
- **判据**：状态「运行中」；连续运行时长 ≥ 24h（突然归零 = 崩溃重启）
- **异常处置**：查 `miniclash.log` 尾部的「已停止/已启动」配对，定位重启原因

### 2. 配置有效
- **取数**：`mihomo -t -d /etc/miniclash -f /etc/miniclash/config.yaml`；
  `rules:` 前 12 条；`nameserver-policy` 段
- **判据**：试读通过；注入规则按预期在前（DIRECT 例外、apple/微软走代理）
- **异常处置**：注入顺序错位会吞掉后续全部规则，表现为 `proxy [自动优选...] not found`；
  改 init.d 的 `EXTRA` 块后必须 `mihomo -t` 再 restart

### 3. 选优健康
- **取数**：`uci get miniclash.core.node`；`/etc/miniclash/judge.log` 近 12 轮 + 全量裁决类型分布
- **判据**：当前节点与最近裁决一致；judge 每 5 分钟一轮无断档；
  裁决以「保持」为主，少量「切换」属正常自愈
- **异常处置**：频繁切换 = 两国延迟接近或节点劣化，看 judge.log 的延迟差值；
  裁决断档 = judge cron 没跑，查 init.d 的 cron 注册

### 4. 流量与套餐
- **取数**：`./scripts/traffic.sh`
- **判据**：剩余流量与天数匹配（剩余 GB / 剩余天数 ≥ 日常均耗）；未过期
- **异常处置**：余量骤降 = 有异常大流量（视频/更新/爬虫），转第 5 项定位

### 5. 流量走向
- **取数**：`./scripts/traffic-audit.sh`
- **判据**：直连占比 > 代理占比（国内流量不该大量走代理）；
  代理桶 Top 域以「确需代理的境外服务」为主
- **异常处置**：见第 9 项

### 6. 告警归因
- **取数**：`miniclash.log` 的 `level=warning` 按错误类型与 `match` 规则聚合
- **判据**：能按已知模式归类即为正常——
  - `connection refused` 127.0.0.1:13013 → 微信客户端本地代理端口，与路由器无关
  - `context deadline exceeded` / `EOF` / `i/o timeout` → 机场入口间歇阻断，短时自愈
  - `dns resolve failed` → 确认目标域，多为子域本就不解析
  - `context canceled` → 上游主动取消
- **异常处置**：出现归不了类的类型，或某类型条数较上轮成倍增长 → 展开逐条看

### 7. 出网实测
- **取数**：Mac 侧 `curl` 测四条路径——代理域（github.com、hf-mirror.com）、
  直连域（www.baidu.com、registry.npmmirror.com）
- **判据**：全部 http=200；代理域解析到 fake-ip 段 `198.18.0.0/16`
- **异常处置**：注意重启后 15 秒内测会假失败（代理连接未预热），要复测

### 8. 规则库时效
- **取数**：`.mihomo-version` vs GitHub latest；路由器上
  `Country.mmdb` / `cn.mrs` 的 md5 vs 上游
- **判据**：内核版本 = 上游 latest
- **异常处置**：内核有新版 → `./scripts/update-kernel.sh`；
  规则库过期 → 备份后上传，`mihomo -t` 通过再 restart

### 9. 分流正确性（人工判读）
- **取数**：第 5 项的代理桶域名 → 在路由器上取真实 IP 并实测真实直连
  ```sh
  # 路由器本机出站不被劫持，用真实 IP 直连才是有效判据
  ip=$(nslookup "$d" 223.5.5.5 2>/dev/null | grep -oE "Address [0-9]+: [0-9.]+" | tail -1 | cut -d" " -f3)
  curl -sk -o /dev/null -w "%{http_code} %{time_total}s\n" --max-time 8 --resolve "$d:443:$ip" "https://$d/"
  ```
- **判据**：
  - 真实 IP 属国内段且**直连明显快于代理** → 不该走代理，加 DIRECT 规则
  - 直连不通或更慢 → 保持代理
  - 属已知有意设计（Apple 全家、微软账号域）→ 不动
- **异常处置**：加规则要同时改 init.d 的 `EXTRA` 块 + 文档，部署后实测并
  复测其余路径确认无回归。**若规则加上去没带来提速，就是没收益，回滚**
  （真实案例：gdtimg.com 加 DIRECT 后仍 2.5s，因为腾讯广告用的是境外 CDN 节点）

---

## 汇报模板

每次巡检按此结构汇报，正常项合并成一句，异常项必须带证据：

```
结论：<健康 / 有 N 项待处理>

异常项：
- <现象> —— 证据：<实测数据> —— 建议：<动作>
  （要飞哥定的放这里，单独列「待决策」）

正常项：<合并一行，不逐项展开>
```

汇报纪律：
- 结论先行，异常项带数字证据（延迟、字节数、条数），不贴整段日志
- 「待决策」与「已做」分开列，不要把已完成的再列成待办
- 判据不明的异常标「待查」，不猜结论
