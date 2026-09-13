#!/bin/bash
# 一键切换 MiniClash 机场（配置在 airports/<机场名>.conf）
# 用法: ./scripts/airport-switch.sh <机场名> [路由器别名，默认 luyou]
# 不带机场名时列出可用机场
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUTER="${2:-luyou}"

# 列出可用机场
if [ -z "$1" ]; then
    echo "可用机场:"
    for f in "$ROOT"/airports/*.conf; do
        [ -f "$f" ] || continue
        echo "  $(basename "$f" .conf)"
    done
    echo "用法: $0 <机场名> [路由器]"
    exit 1
fi

NAME="$1"
CONF="$ROOT/airports/$NAME.conf"
[ -f "$CONF" ] || { echo "错误: 未找到 $CONF"; exit 1; }

# shellcheck disable=SC1090
. "$CONF"
[ -n "$URL" ] || { echo "错误: $CONF 缺少 URL"; exit 1; }

echo "==> 切换机场: $NAME"
echo "    订阅: ${URL%%\?*}"
echo "    候选: $NODES"
[ -n "$NOTE" ] && echo "    备注: $NOTE"

echo "==> 写入配置并重启 (路由器 $ROUTER)"
# 单次 ssh 完成: 写 URL/nodes → force_update=1 强制拉订阅 → 重启 → 恢复 force_update → 回显状态
# UCI 值用单引号保护（节点名含空格 / 反斜杠，如 "澳大利亚  DF2 官网dfhl1.com"）
ssh "$ROUTER" "
uci set miniclash.core.url='$URL'
uci set miniclash.core.nodes='$NODES'
uci set miniclash.core.force_update='1'
uci commit miniclash
/etc/init.d/miniclash restart
sleep 2
uci set miniclash.core.force_update='0'
uci commit miniclash
/etc/init.d/miniclash status
"

echo "==> 切换完成，实测国外访问"
curl -s -o /dev/null -w "    github → HTTP %{http_code} (%{time_total}s)\n" --max-time 15 https://github.com || echo "    github → 不通"
