#!/bin/bash
# 巡检取数：一次跑完巡检清单 1~8 项，输出结构化结果。
# 判据与异常处置见 docs/inspection.md；第 9 项（分流正确性）需人工判读。
# 用法: ./scripts/inspect.sh
set -uo pipefail

ROUTER=luyou
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=/etc/miniclash/miniclash.log

echo "━━━ 1. 服务存活 ━━━"
ssh "$ROUTER" 'pid=$(pidof mihomo); if [ -z "$pid" ]; then echo "[!!] mihomo 未运行"; exit 0; fi
up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1); st=$(awk "{print \$22}" /proc/$pid/stat)
m=$(( (up - st/100) / 60 ))
h=$(( m / 60 ))
[ "$m" -lt 60 ] && tag="新" && note="（刚重启不久）"
[ "$m" -ge 60 ] && [ "$m" -lt 1440 ] && tag="注意" && note="（24h 内重启过）"
[ "$m" -ge 1440 ] && tag="OK" && note=""
printf "[%s] 运行中 (PID %s)，连续 %s 小时 %s 分%s\n" "$tag" "$pid" "$h" "$(( m % 60 ))" "$note"' 2>/dev/null

echo
echo "━━━ 2. 配置有效 ━━━"
ssh "$ROUTER" "/usr/bin/mihomo -t -d /etc/miniclash -f /etc/miniclash/config.yaml 2>&1 | tail -1" 2>/dev/null | sed 's/^/  /'
ssh "$ROUTER" 'awk "/^rules:/{f=1;next} f&&/^ *- /{print; c++} c>=3{exit}" /etc/miniclash/config.yaml' 2>/dev/null | sed 's/^/  /'

echo
echo "━━━ 3. 选优健康 ━━━"
ssh "$ROUTER" 'echo "  当前节点: $(uci get miniclash.core.node)"; tail -6 /etc/miniclash/judge.log | sed "s/^/  /"' 2>/dev/null
ssh "$ROUTER" 'grep -o "保持 [^-]*\|切换 [^-]*" /etc/miniclash/judge.log | sort | uniq -c | sed "s/^/  累计裁决: /"' 2>/dev/null

echo
echo "━━━ 4. 流量与套餐 ━━━"
"$HERE/traffic.sh" 2>/dev/null | sed 's/^/  /'

echo
echo "━━━ 5. 流量走向 ━━━"
"$HERE/traffic-audit.sh" 2>/dev/null | sed -n '/总量/,/合计/p;/兜底走代理/,/^$/p' | sed 's/^/  /' | head -24

echo
echo "━━━ 6. 告警归因（近 3 天日志）━━━"
ssh "$ROUTER" "grep 'level=warning' $LOG | sed 's/^time=[^ ]* level=warning msg=//' | sed 's/.*error: //' | sed 's/[0-9]\{2,\}/N/g' | cut -c1-46 | sort | uniq -c | sort -rn | head -6" 2>/dev/null | sed 's/^/  /'
ssh "$ROUTER" "grep 'level=warning' $LOG | grep -oE 'match [A-Za-z]+/[a-zA-Z-]+' | sort | uniq -c | sort -rn | head -5" 2>/dev/null | sed 's/^/  规则命中: /'

echo
echo "━━━ 7. 出网实测 ━━━"
for u in https://github.com/robots.txt https://hf-mirror.com/ https://www.baidu.com/ https://registry.npmmirror.com/; do
  printf "  %-38s " "$u"
  curl -sk -o /dev/null -w "http=%{http_code} %{time_total}s ip=%{remote_ip}\n" --max-time 15 "$u"
done

echo
echo "━━━ 8. 规则库时效 ━━━"
latest=$(curl -fsSL --max-time 15 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | cut -d'"' -f4)
cur=$(cat "$(dirname "$HERE")/.mihomo-version" 2>/dev/null || echo "?")
[ "$cur" = "$latest" ] && echo "  [OK] 内核 $cur = 上游最新" || echo "  [!!] 内核本地 $cur / 上游 $latest（可跑 update-kernel.sh）"
for f in Country.mmdb cn.mrs; do
  l=$(md5 -q "$(dirname "$HERE")/root/etc/miniclash/$f" 2>/dev/null)
  r=$(ssh "$ROUTER" "md5sum /etc/miniclash/$f 2>/dev/null | cut -d' ' -f1" 2>/dev/null)
  [ -n "$l" ] && [ "$l" = "$r" ] && echo "  [OK] $f 路由器与仓库一致" || echo "  [!!] $f 路由器($r) != 仓库($l)"
done

echo
echo "━━━ 9. 分流正确性：需人工判读 ━━━"
echo "  见 docs/inspection.md 第 9 项：取第 5 项代理桶域名，"
echo "  在路由器上用真实 IP 实测直连，再与代理耗时对比。"
