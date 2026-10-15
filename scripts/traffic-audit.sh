#!/bin/bash
# 流量走向审计（巡检用）：聚合路由器 meter CSV，回答"流量走得是否合理"。
# meter 每分钟采样 mihomo 连接、按域名/设备/是否代理记字节增量，见 docs/architecture.md。
# 用法: ./scripts/traffic-audit.sh [天数]    默认 3 天
set -euo pipefail

ROUTER=luyou
DAYS=${1:-3}

ssh "$ROUTER" "sh -s $DAYS" <<'REMOTE'
DAYS=$1
cd /mnt/mmcblk0p7/logs/miniclash 2>/dev/null || { echo "meter 目录不可达（大分区未挂载？）"; exit 1; }
FILES=$(ls -t meter-*.csv 2>/dev/null | head -"$DAYS" | tr '\n' ' ')
[ -n "$FILES" ] || { echo "无 meter 数据"; exit 1; }

echo "统计文件: $FILES"

echo
echo "━━━ 总量：代理 vs 直连 ━━━"
awk -F, '{if($5==1)p+=$6+$7; else d+=$6+$7} END{
  printf "代理 %8.2f GB    直连 %8.2f GB    合计 %8.2f GB\n",
         p/1073741824, d/1073741824, (p+d)/1073741824}' $FILES

echo
echo "━━━ 代理流量 Top 15（吃套餐的部分）━━━"
awk -F, '$5==1{t[$3]+=$6+$7} END{for(k in t) printf "%9.1f MB  %s\n", t[k]/1048576, k}' $FILES \
  | sort -rn | head -15

echo
echo "━━━ 兜底走代理（无专门规则匹配，重点核查是否本可直连）━━━"
awk -F, '$5==1 && ($4==""||$4=="Match"){t[$3]+=$6+$7} END{for(k in t) printf "%9.1f MB  %s\n", t[k]/1048576, k}' $FILES \
  | sort -rn | head -15

echo
echo "━━━ 按设备（源 IP）━━━"
awk -F, '{t[$2"|"($5==1?"代理":"直连")]+=$6+$7} END{for(k in t) printf "%8.2f GB  %s\n", t[k]/1073741824, k}' $FILES \
  | sort -rn | head -10

echo
echo "注：meter 只统计采样时仍存活的长连接；两次采样间建立又结束的短连接漏计"
echo "    （视频/下载/系统更新等流量大头必被抓）。路由器之外的流量（手机直连机场）不计入。"
REMOTE
