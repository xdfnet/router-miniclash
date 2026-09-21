#!/bin/bash
# 查看 BoostNet 套餐信息（剩余流量/重置/到期/官网），信息条目藏在订阅 proxies 段
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL=$(cat "$ROOT/subscription.url")
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
curl -fsSL --max-time 30 -A 'clash-verge/v2.2.6' -o "$TMP" "$URL"

# 只取 proxies 段（proxy-groups 段引用同名会重复），提取信息条目的 name 值
awk '/^proxies:/{p=1;next}/^[a-z-]+:/{p=0}p' "$TMP" \
    | grep -E '剩余流量|重置|套餐到期|永久官网' \
    | grep -oE "name: ('[^']*'|[^,}]+)" | sed "s/name: //;s/^'//;s/'$//" \
    | sed -e 's/距离下次重置剩余/下次重置/' -e 's/永久官网:/永久官网: /' -e 's/：/: /g'
