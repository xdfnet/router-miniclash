#!/bin/bash
# 干预复核：已生效的域名规则，现在还该留着吗？
#
# 巡检第 9 项的一部分（与 domain-candidates.sh 配套）：
#   domain-candidates.sh 看**新**域名该不该加规则；
#   本脚本看**已加**的规则还有没有存在价值——要么它失效了（直连不通），
#   要么它没收益了（走代理反而更快），这两种都该撤。
#
# 为什么必须复核（2026-10-29 实测）：
#   1. CDN 边缘节点会变：vsassets.io 同一天测两轮，"直连快 11 倍"和"代理快 120 倍"
#      两种结论都出现过——今天加的规则，明天就可能有害。
#   2. 规则是长期留着的，环境却一直在变；不复核就会留下一堆当年有用、
#      现在有害或无用的规则。
#
# 关键：**用真实在用的主机名去测**，不能拿规则里的裸域名测。
#   boost1.shop 本身没有 A 记录（真实订阅地址是 sub.boost1.shop），
#   拿裸域名测会误报"直连不通"。所以每个规则的真实主机从 meter 里取
#   （meter 记了每条连接的命中规则与真实 host）。
#
# 怎么测"代理路径"（DIRECT 规则的域名在规则生效时走直连，测不到代理路径）：
#   临时把 mihomo 切 global 模式、GLOBAL 组指向当前节点 → 所有流量无视规则走该节点；
#   测完立刻切回 rule 模式（窗口几秒，脚本里有 trap 兜底）。
#
# 判据（与 docs/domain-rules.md 一致）：
#   直连不通              → ⚠ 必须改成代理
#   代理明显快（≥1.6 倍） → ⚠ 建议撤销（或改走代理）
#   差异不显著            → 保持
#   状态码不一致          → 不可比，人工看
#
# 用法: ./scripts/domain-review.sh [天数，默认 7]
set -uo pipefail

ROUTER=luyou
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAYS=${1:-7}

# ── 规则来源：仓库里 init.d 的 EXTRA 块（唯一真源）──
RULES=$(sed -n '/^ *EXTRA="/,/"$/p' "$ROOT/root/etc/init.d/miniclash" \
    | grep -oE '\- [A-Z-]+,[^,]+,(DIRECT|\$group)' \
    | sed 's/^- //; s/,$group$/,PROXY/')
[ -n "$RULES" ] || { echo "（未解析到规则，检查 init.d 的 EXTRA 块）"; exit 0; }

secret=$(ssh -n "$ROUTER" 'cat /etc/miniclash/api_secret' 2>/dev/null)
current_node=$(ssh -n "$ROUTER" 'uci -q get miniclash.core.node' 2>/dev/null)
[ -n "$secret" ] || { echo "（拿不到 api_secret）"; exit 0; }

# ── 每条规则真实在用的主机（meter 里按命中规则取流量最大的 host）──
host_for_rule() {
    ssh "$ROUTER" "sh -s $DAYS $1" <<'REMOTE' 2>/dev/null
DAYS=$1; PAT=$2
cd /mnt/mmcblk0p7/logs/miniclash 2>/dev/null || exit 0
FILES=$(ls -t meter-*.csv 2>/dev/null | head -"$DAYS" | tr '\n' ' ')
[ -n "$FILES" ] || exit 0
awk -F, -v p="$PAT" '$3 ~ /\./ && $3 !~ /^[0-9.]+$/ && ($4 ~ p) {t[$3]+=$6+$7}
     END{for(k in t) printf "%9.1f %s\n", t[k]/1048576, k}' $FILES | sort -rn | head -2 | awk '{print $2}'
REMOTE
}

# ── 探针 ──
# 直连：路由器本机出站不被劫持，用国内 DNS 解析出的真实 IP 直连；
# 国内 DNS 没答案（境外域名）时回落用 DoH 经节点解析——否则会误报"直连不通"
resolve_ip() {
    ssh -n "$ROUTER" "d=$1; ip=\$(nslookup \$d 223.5.5.5 2>/dev/null | grep -oE 'Address [0-9]+: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1 | cut -d' ' -f3); if [ -z \"\$ip\" ]; then ip=\$(curl -s --max-time 8 -x http://127.0.0.1:7893 -H 'accept: application/dns-json' \"https://1.1.1.1/dns-query?name=\$d&type=A\" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1); fi; echo \"\$ip\"" 2>/dev/null | tr -d '\r' | tail -1
}
probe_direct() {
    local ip
    ip=$(resolve_ip "$1")
    [ -z "$ip" ] && { echo "NODNS 0"; return; }
    ssh -n "$ROUTER" "curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 12 --resolve \"$1:443:$ip\" \"https://$1/\" 2>/dev/null; true" 2>/dev/null | tr -d '\r' | tail -1
}
probe_mac() {
    local out
    out=$(curl -sk -o /dev/null -w '%{http_code} %{time_total}' --max-time 15 "https://$1/" 2>/dev/null)
    case "$out" in *" "*) echo "$out" ;; *) echo "000 0" ;; esac
}

# ── 解析落点（铁律 2）──
# mihomo 里"规则走向"同时决定"用哪套 DNS 解析"：
#   DIRECT 规则 → dns.direct-nameserver（国内 DNS 223.5.5.5 / 119.29.29.29）
#   PROXY  规则 → dns.nameserver（国外 DoH，经节点）
# 所以给 DIRECT 域名定规则前必须先看**国内 DNS 给的是不是国内落点**：
# 国内 DNS 给不出答案（或只给境外 IP）时，"直连"同样是绕地球，规则等于白加。
# 2026-10-29 的地图事故就是这个：ls.apple.com 若只加 DIRECT 而不落到国内 CDN，瓦片照旧慢。
resolve_cn_ip() {
    ssh -n "$ROUTER" "nslookup \"$1\" 223.5.5.5 2>/dev/null | grep -oE 'Address [0-9]+: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1 | cut -d' ' -f3" 2>/dev/null | tr -d '\r' | tail -1
}
resolve_doh_ip() {
    ssh -n "$ROUTER" "curl -s --max-time 8 -x http://127.0.0.1:7893 -H 'accept: application/dns-json' \"https://1.1.1.1/dns-query?name=$1&type=A\" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1" 2>/dev/null | tr -d '\r' | tail -1
}

# ── 遮蔽检查（铁律 1）──
# mihomo 的规则是**先命中先生效**：排在前面的更宽规则会把后面的细规则整条吃掉。
# 族内落点不同就必须拆细（Apple：地图瓦片落国内 CDN、账号推送落境外不可直连），
# 一条 apple.com 一刀切就会把细的遮蔽掉——2026-10-29 地图事故就是被它拖慢的。
# 这里静态扫运行期规则表：找出"排在自己前面、且能匹配自己域名"的规则。
RULES_JSON=$(ssh -n "$ROUTER" "curl -s -H 'Authorization: Bearer $secret' http://127.0.0.1:9090/rules" 2>/dev/null)
type_map() {
    case "$1" in
        DOMAIN-SUFFIX) echo DomainSuffix ;;
        DOMAIN-KEYWORD) echo DomainKeyword ;;
        DOMAIN) echo Domain ;;
        *) echo "$1" ;;
    esac
}
shadow_of() {  # $1=规则类型 $2=域名 $3=本规则走向 → "序号 域名 走向"（无则空）
    [ -z "$RULES_JSON" ] && { echo ""; return; }
    printf '%s' "$RULES_JSON" | jq -r --arg t "$(type_map "$1")" --arg d "$2" '
        .rules as $r
        | ($r | map(select(.type==$t and .payload==$d)) | sort_by(.index) | .[0].index) as $own
        | if $own == null then "" else
          ($r | map(select(.index < $own)
                 | select(
                     (.type=="DomainSuffix" and (((($d|ascii_downcase) as $dd | (.payload|ascii_downcase) as $p | ($dd==$p or ($dd|endswith("."+$p)))))))
                     or (.type=="DomainKeyword" and (((($d|ascii_downcase) as $dd | (.payload|ascii_downcase) as $p | ($dd|contains($p))))))
                     or (.type=="Domain" and (((($d|ascii_downcase) as $dd | (.payload|ascii_downcase) as $p | ($dd==$p)))))
                   ))
                 | sort_by(.index) | .[0]) as $hit
          | if $hit == null then "" else "\($hit.index) \($hit.payload) \($hit.proxy)" end
          end' 2>/dev/null
}

# 代理路径：global 模式无视规则，全部走 GLOBAL 组指定的节点
restore_mode() {
    ssh -n "$ROUTER" "curl -s --max-time 5 -X PUT -H 'Authorization: Bearer $secret' -H 'Content-Type: application/json' -d '{\"mode\":\"rule\"}' http://127.0.0.1:9090/configs >/dev/null 2>&1" 2>/dev/null
}
trap restore_mode EXIT

probe_proxy_global() {
    ssh -n "$ROUTER" "curl -s --max-time 5 -X PUT -H 'Authorization: Bearer $secret' -H 'Content-Type: application/json' -d '{\"name\":\"$current_node\"}' http://127.0.0.1:9090/proxies/GLOBAL >/dev/null 2>&1" 2>/dev/null
    ssh -n "$ROUTER" "curl -s --max-time 5 -X PUT -H 'Authorization: Bearer $secret' -H 'Content-Type: application/json' -d '{\"mode\":\"global\"}' http://127.0.0.1:9090/configs >/dev/null 2>&1" 2>/dev/null
    sleep 1
    probe_mac "$1"
    restore_mode
}

echo "干预复核（已生效规则：真实主机 直连路径 vs 代理路径；代理路径用 global 模式实测）"
printf "%-24s %-28s %-7s %-30s %-18s %-15s %-15s %s\n" "规则域名" "实测主机" "走向" "解析落点(国内DNS/境外DoH)" "遮蔽" "直连(状态/秒)" "代理(状态/秒)" "判定"

while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    dom=$(echo "$rule" | cut -d, -f2)
    target=$(echo "$rule" | cut -d, -f3)

    # 真实主机：meter 里命中该规则、流量最大的 host（裸域名常常没有 A 记录，
    # 例如 boost1.shop 本体不解析，真正在用的是 sub./vercdn.boost1.shop）
    host=$(host_for_rule "$dom" | head -1)
    if [ -z "$host" ]; then
        case "$dom" in
            officecdn) host=officecdn.microsoft.com ;;
            xiaohongshu) host=www.xiaohongshu.com ;;
            microsoftonline.com) host=login.microsoftonline.com ;;
            delivery.mp.microsoft.com) host=dl.delivery.mp.microsoft.com ;;
            boost1.shop) host=sub.boost1.shop ;;
            ls.apple.com) host=gspe19-cn-ssl.ls.apple.com ;;
            apple-mapkit.com) host=cdn.apple-mapkit.com ;;
            *) host="$dom" ;;
        esac
    fi

    d1=$(probe_direct "$host"); d2=$(probe_direct "$host")
    dc1=$(echo "$d1" | awk '{print $1}'); dc2=$(echo "$d2" | awk '{print $1}')
    dt1=$(echo "$d1" | awk '{print $2}'); dt2=$(echo "$d2" | awk '{print $2}')
    dt=$(awk "BEGIN{print ($dt1 + $dt2)/2}")

    # 解析落点（铁律 2）：国内 DNS 给什么、境外 DoH 给什么
    cn_ip=$(resolve_cn_ip "$host"); doh_ip=$(resolve_doh_ip "$host")
    [ -n "$cn_ip" ] && land="国内$cn_ip" || land="国内无答案"
    [ -n "$doh_ip" ] && land="$land/境外$doh_ip"

    # 遮蔽检查（铁律 1）：前面有没有更宽的规则把这条吃掉
    shadow=$(shadow_of "$(echo "$rule" | cut -d, -f1)" "$dom" "$target")
    if [ -n "$shadow" ]; then
        shadow_txt="第$(echo "$shadow" | cut -d' ' -f1)条 $(echo "$shadow" | cut -d' ' -f2)"
    else
        shadow_txt="—"
    fi

    if [ "$target" = "DIRECT" ]; then
        # 直连规则：代理路径必须用 global 模式测（规则生效时是走直连的）
        p1=$(probe_proxy_global "$host"); p2=$(probe_proxy_global "$host")
    else
        # 代理规则：Mac 侧请求按规则走代理，直接测即可
        p1=$(probe_mac "$host"); p2=$(probe_mac "$host")
    fi
    pcode=$(echo "$p1" | awk '{print $1}')
    pt1=$(echo "$p1" | awk '{print $2}'); pt2=$(echo "$p2" | awk '{print $2}')
    pt=$(awk "BEGIN{print ($pt1 + $pt2)/2}")

    if [ "$dc1" = "NODNS" ] || [ "$dc2" = "NODNS" ]; then
        verdict="域名无解析记录 → 规则当前无作用（不是故障）"
    elif [ "$dc1" = "000" ] || [ "$dc2" = "000" ]; then
        verdict="⚠ 直连不通 → 必须改成代理"
    elif [ "$dc1" != "$dc2" ]; then
        verdict="状态码不一致，不可比（人工看）"
    elif [ "$pcode" = "000" ]; then
        verdict="代理路径也不通（服务端问题，非分流问题）"
    elif awk "BEGIN{exit !($dt>0 && $pt>0 && $pt*1.6 <= $dt)}"; then
        # 代理明显快（比例是 直连/代理，不是反过来）
        verdict="⚠ 代理快 $(awk "BEGIN{printf \"%.1f\", $dt/$pt}") 倍 → 建议撤销/改走代理"
    elif awk "BEGIN{exit !($dt>0 && $pt>0 && $dt*1.6 <= $pt)}"; then
        # 直连明显快
        if [ "$target" = "DIRECT" ]; then
            verdict="直连快 $(awk "BEGIN{printf \"%.1f\", $pt/$dt}") 倍，保持"
        else
            verdict="⚠ 直连快 $(awk "BEGIN{printf \"%.1f\", $pt/$dt}") 倍 → 建议撤销/改走直连"
        fi
    elif awk "BEGIN{exit !($pt>0 && $dt <= $pt)}"; then
        verdict="直连不劣但差异不显著（保持）"
    else
        verdict="代理更快，保持"
    fi

    # 铁律 2 追加：DIRECT 规则若国内 DNS 给不出落点，直连同样是绕地球
    if [ "$target" = "DIRECT" ] && [ -z "$cn_ip" ]; then
        verdict="⚠ 国内DNS无答案（无国内落点，直连=绕地球）→ $verdict"
    fi
    # 铁律 1 追加：被更宽的规则遮蔽 → 这条规则永不生效
    if [ -n "$shadow" ]; then
        verdict="⚠ 被第$(echo "$shadow" | cut -d' ' -f1)条 $(echo "$shadow" | cut -d' ' -f2)→$(echo "$shadow" | cut -d' ' -f3) 遮蔽（永不生效）→ $verdict"
    fi

    printf "%-24s %-28s %-7s %-30s %-18s %-15s %-15s %s\n" "$dom" "$host" "$target" "$land" "$shadow_txt" "$d1/$d2" "$p1/$p2" "$verdict"
done <<< "$RULES"

echo
echo "处置：判 ⚠ 的规则要么改走向、要么从 init.d 的 EXTRA 块删掉；"
echo "      删完必须同一次提交里更新 docs/domain-rules.md（记明实测数据与撤销原因）。"
echo "两条铁律（见 docs/domain-rules.md）："
echo "  ① 干预单位=能独立取证的业务路径，不是域族——族内落点不同必须拆细；"
echo "     「遮蔽」列报的 ⚠ 就是宽规则把细规则吃掉了（Apple 地图事故的成因）。"
echo "  ② 加 DIRECT 必须同时确认解析落点——国内 DNS 给不出国内落点的，直连也是绕地球。"
