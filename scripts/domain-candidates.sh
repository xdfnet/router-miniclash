#!/bin/bash
# 干预候选分析：哪些"兜底走代理"的域名其实该走直连？
#
# 数据来源 = meter 的"兜底走代理"桶（没命中任何专门规则、被动走代理的域名）。
# 判据与处置流程见 docs/domain-rules.md 第三节；本脚本只出**对照数据与判定**，
# 加不加规则是人的决定（且必须同步写进 docs/domain-rules.md）。
#
# 为什么必须自动化：人工只看"谁在吃代理流量"会漏掉直连明显更快的域名
# （2026-10-29 实测 dl.google.com 走代理 0.1MB/s vs 直连 13MB/s，差 100 倍，
#  而它在桶里排第 14 位——不逐个对照根本发现不了）。
#
# 判定的坑（2026-10-29 实测踩到）：
#   ① 单次采样会翻转（cdn.nuphy.io 直连 1.50s→1.80s、代理 1.69s→0.42s）→ 取 2 轮，都快才算。
#   ② 直连拿到 CDN 边缘节点的 302/403 不等于"服务可用"（claude.ai 直连 302 看着比代理快，
#      加了 DIRECT 就会直接搞坏 Claude）→ **直连与代理的 HTTP 状态码不一致时不可比，不报候选**。
#
# 用法: ./scripts/domain-candidates.sh [候选数，默认 6] [天数，默认 3]
set -uo pipefail

ROUTER=luyou
TOP=${1:-6}
DAYS=${2:-3}

# 候选域名：meter 兜底桶里的域名项（跳过裸 IP——那是没嗅探出域名的连接，改不了规则）
CANDS=$(ssh "$ROUTER" "sh -s $DAYS $TOP" <<'REMOTE' 2>/dev/null
DAYS=$1; TOP=$2
cd /mnt/mmcblk0p7/logs/miniclash 2>/dev/null || exit 0
FILES=$(ls -t meter-*.csv 2>/dev/null | head -"$DAYS" | tr '\n' ' ')
[ -n "$FILES" ] || exit 0
awk -F, '$5==1 && ($4==""||$4=="Match") && $3 ~ /\./ && $3 !~ /^[0-9.]+$/ {t[$3]+=$6+$7}
     END{for(k in t) printf "%9.1f %s\n", t[k]/1048576, k}' $FILES | sort -rn | head -"$TOP" | awk '{print $2}'
REMOTE
)

[ -n "$CANDS" ] || { echo "（无候选域名：兜底桶里没有域名项，或 meter 不可达）"; exit 0; }

# 已记录在 docs/domain-rules.md 且判定为"必须代理"的域名：跳过，只看新面孔
KNOWN_MUST=$(awk -F'|' '/必须代理/ {gsub(/[ `]/,"",$2); print $2}' docs/domain-rules.md 2>/dev/null | tr '\n' ' ')

# 直连一次：路由器本机出站不被劫持，用国内 DNS 解析出的真实 IP 直连才是有效判据
# 输出 "状态码 耗时"
probe_direct() {
    ssh "$ROUTER" "d=$1; ip=\$(nslookup \$d 223.5.5.5 2>/dev/null | grep -oE 'Address [0-9]+: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1 | cut -d' ' -f3); [ -z \"\$ip\" ] && { echo 'NODNS 0'; exit 0; }; curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 12 --resolve \"\$d:443:\$ip\" \"https://\$d/\" 2>/dev/null; true" 2>/dev/null | tr -d '\r' | tail -1
}

# 代理一次：Mac 侧走透明代理（路由器本机出站不走代理，不能在路由器上测代理路径）
probe_proxy() {
    local out
    out=$(curl -sk -o /dev/null -w '%{http_code} %{time_total}' --max-time 15 "https://$1/" 2>/dev/null)
    case "$out" in
        *" "*) echo "$out" ;;
        *) echo "000 0" ;;
    esac
}

echo "干预候选分析（兜底走代理的域名 → 直连/代理对照，2 轮）"
printf "%-40s %-16s %-16s %s\n" "域名" "直连(状态/秒)" "代理(状态/秒)" "判定"

for d in $CANDS; do
    case " $KNOWN_MUST " in
        *" $d "*) echo "$d —— 已记录：必须代理，跳过"; continue ;;
    esac
    d1=$(probe_direct "$d"); p1=$(probe_proxy "$d")
    d2=$(probe_direct "$d"); p2=$(probe_proxy "$d")

    # 取"状态码一致"的那一轮为主；不一致就说明直连拿到的是不同的 CDN 落点，不可比
    c1=$(echo "$d1" | awk '{print $1}'); t1=$(echo "$d1" | awk '{print $2}')
    c2=$(echo "$d2" | awk '{print $1}'); t2=$(echo "$d2" | awk '{print $2}')
    pc=$(echo "$p1" | awk '{print $1}'); pt=$(echo "$p1" | awk '{print $2}')
    pc2=$(echo "$p2" | awk '{print $1}'); pt2=$(echo "$p2" | awk '{print $2}')

    dt=$(awk "BEGIN{print ($t1+$t2)/2}")
    pt=$(awk "BEGIN{print ($pt+$pt2)/2}")

    # 代理侧取"成功轮"的状态码（偶尔有一轮 000 是抖动）
    pcode_ok=$pc; [ "$pc" = "000" ] && pcode_ok=$pc2
    if [ "$c1" = "NODNS" ] || [ "$c1" = "000" ] || [ "$c2" = "000" ] || [ "$c2" = "NODNS" ]; then
        verdict="必须代理（直连不通）"
    elif [ "$c1" != "$c2" ]; then
        # 两轮直连状态码不同（如一轮 403 一轮 302）→ 落点不稳定，不可比
        verdict="状态码不一致，不可比（直连拿到的是另一处 CDN，人工看）"
    elif [ "$c1" != "$pcode_ok" ]; then
        # 直连与代理状态码不同 = 直连落在另一个端点（多半不是同一个服务）→ 不可比
        # claude.ai 就是这种：直连 302、代理 403，根路径看着"直连更快"，
        # 照着加 DIRECT 会直接搞坏 Claude——所以状态码必须一致才敢报候选。
        verdict="直连/代理状态码不同(直连 $c1 vs 代理 $pcode_ok)，不可比，人工看"
    elif awk "BEGIN{exit !($pt>0 && $dt*1.6 <= $pt)}"; then
        verdict=">> 候选：直连快 ${pt}→${dt}s，用真实文件复核后再决定"
    elif awk "BEGIN{exit !($pt>0 && $dt <= $pt)}"; then
        verdict="直连不劣但差异不显著（收益边际，按判据可不加）"
    else
        verdict="代理更快，保持现状"
    fi
    printf "%-40s %-16s %-16s %s\n" "$d" "$d1/$d2" "$p1/$p2" "$verdict"
done

echo
echo "处置：只有判「候选」的域名才考虑加规则，且必须按 docs/domain-rules.md 第三节"
echo "      用真实文件（不是根路径）复核吞吐，改完同一次提交里把结论写进 docs/domain-rules.md。"
echo "      「没带来提速就是没收益」——加了没收益就回滚。"
