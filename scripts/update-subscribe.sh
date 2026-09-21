#!/bin/bash
# 本地拉取 BoostNet 订阅 → 过滤仅日本/新加坡节点 → 上传路由器并重启
# 路由器不保存订阅地址；用法: ./scripts/update-subscribe.sh [路由器别名，默认 luyou]
set -e

ROUTER="${1:-luyou}"
URL='https://sub.boost1.shop/d/ffcce85760a36bd44a367cebcb2c97a5'
KEEP='日本|新加坡'

TMP=$(mktemp); trap 'rm -f "$TMP" "$TMP.d" "$TMP.f"' EXIT

echo "==> 拉取订阅"
curl -fsSL --max-time 30 -A 'clash-verge/v2.2.6' -o "$TMP" "$URL"
# base64 包裹检测（BSD/GNU base64 兼容）
if head -c 128 "$TMP" | grep -qE '^[A-Za-z0-9+/=]{40,}$'; then
    base64 -D -i "$TMP" -o "$TMP.d" 2>/dev/null || base64 -d "$TMP" > "$TMP.d"
    mv "$TMP.d" "$TMP"
fi
grep -q '^proxies:' "$TMP" || { echo "订阅不含 proxies: 段"; exit 1; }

echo "==> 过滤节点（仅日本/新加坡），删除订阅自带 proxy-groups"
# proxies 段只保留日本/新加坡节点（订阅单行流式），proxy-groups 整段删除
# （自带组引用全部节点，保留会因缺失节点导致内核加载失败；组由路由 gen_config 统一生成）
awk -v keep="$KEEP" '
    /^proxies:/ { inp=1; print; next }
    inp && /^[a-z-]+:/ { inp=0 }
    inp { if ($0 ~ ("name: (" keep ")")) print; next }
    /^proxy-groups:/ { skip=1; next }
    skip && /^[a-z-]+:/ { skip=0 }
    skip { next }
    { print }
' "$TMP" > "$TMP.f"

n=$(grep -cE 'name: (日本|新加坡)' "$TMP.f")
[ "$n" -eq 16 ] || { echo "过滤后节点数异常: $n（期望 16）"; exit 1; }

echo "==> 上传并重启 (路由器 $ROUTER)"
ssh "$ROUTER" 'mkdir -p /etc/miniclash'
scp "$TMP.f" "$ROUTER:/etc/miniclash/subscribe.yaml"
ssh "$ROUTER" '/etc/init.d/miniclash restart'

echo "==> 实测国外访问"
curl -s -o /dev/null -w "    github → HTTP %{http_code} (%{time_total}s)\n" --max-time 15 https://github.com || echo "    github → 不通"
