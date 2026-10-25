#!/bin/sh
# judge — 跨国线路自动裁决（cron 每 15 分钟）
#
# 判据是"真实下载带宽"，不是延迟。理由（2026-10-24 实测）：
#   ① mihomo 的 delay API 只测建连+首字节(TTFB)，不随响应体大小增长，
#      同一节点同一 URL 1MB 与 8MB 耗时相同 → 它测不出带宽；
#   ② 延迟与带宽并不同向：日本组真实下载快 41%，延迟却略高于新加坡。
#      按延迟选会稳定选到慢线路。
#   带宽由 probe.sh 实测（每个节点一个 pinned listener，下载真实内容测速）。
#
# 两层判据，各司其职：
#   紧急逃生（免费、即时）：读内核 url-test 的 alive 状态——内核自己每 60s 测一次，
#      本地 API 读，不产生外网流量。当前国活节点 < 2 → 立刻切到活节点最多的国家，
#      不等带宽测速。
#   择优：带宽节点分 = 该节点最近 4 次测量的中位数（单次噪声可达 55%，中位数抗噪）；
#      国家分 = 该国节点分最高的前 2 个的平均；连续 2 次同一候选 + 领先 25% 才切
#      ——双确认 + margin，防打地鼠横跳。
#
# 流量预算：每轮只测 8 个节点（每国 4 个轮转窗口，2 轮覆盖全部 8 个）× 1MB ≈ 8MB/轮，
#   15 分钟一轮 ≈ ~864MB/天（占剩余配额约 0.6%）。
#   样本从 256KB 提到 1MB 的原因：256KB 把握手当带宽且会让国家排序翻转（2026-10-25 实测）。
#   测速必须串行（并发互抢带宽会毁掉排序，2026-10-24 实测）。
#
# BOOT=1：开机/重启模式，测一次直接进最优国（绕过双确认），由 init.d start() 调用。

WORKDIR=/etc/miniclash
STATE=/tmp/miniclash_judge.state      # 防抖计数（保持/切换成功时清空）
ROTF=/tmp/miniclash_judge_rot.state    # 每国测速轮转指针（跨轮保留，不能跟着 STATE 一起清）
HIST=/tmp/miniclash_bandwidth.state
TOTALF=/tmp/miniclash_bandwidth.total
JLOG=$WORKDIR/judge.log     # judge 裁决历史（独立文件，不被内核 warning 淹没）
LOG=$WORKDIR/miniclash.log  # 内核 warning + init.d 事件
SECRET=$(cat $WORKDIR/api_secret 2>/dev/null)
API=http://127.0.0.1:9090

get() { uci -q get miniclash.core.$1 2>/dev/null; }
log() { echo "[$(date '+%F %T')] [judge] $*" >> $JLOG; }

# 停用 / 手动 stop 时静默退出
[ "$(get enabled)" = "1" ] || exit 0
group=$(get group); group=${group:-自动优选}
# 参与裁决的国家（有序，第 1 个为 select 默认；单一场景固化）
countries=日本,新加坡
country_list=$(echo "$countries" | tr ',' ' ')

# URL 编码（逐字节；中文 UTF-8 按字节编码正是所需）
urlencode() {
    local s=$1 out= c= i=1
    while [ $i -le ${#s} ]; do
        c=$(expr substr "$s" $i 1)
        case "$c" in
            [a-zA-Z0-9.~_-]) out=$out$c ;;
            *) out=$out$(printf '%%%02X' "'$c") ;;
        esac
        i=$((i+1))
    done
    echo "$out"
}

# 节点名归集（与 init.d gen_config 同一规则）
all_names=$(awk '/^proxies:/{p=1;next}/^[a-z-]+:/{p=0}p' $WORKDIR/subscribe.yaml \
    | grep -oE "name: [^,}]+" | sed "s/name: //; s/^'//; s/'$//")

# 该国节点列表（订阅顺序）
nodes_of() {
    for n in $all_names; do case "$n" in "$1"*) echo "$n" ;; esac; done
}

# 内核 url-test 每 60s 自测的健康状态（本地 API 读，不产生外网流量）
alive_of() {
    curl -s --max-time 3 -H "Authorization: Bearer $SECRET" \
        "$API/proxies/$(urlencode "$1")" | grep -q '"alive":true' && echo 1 || echo 0
}

# 该国活节点数
alive_count() {
    c=$1; n=0
    for node in $(nodes_of "$c"); do
        a=$(alive_of "$node")
        n=$((n + a))
    done
    echo $n
}

# 读取/设置主 select 组的选中项
get_group() {
    curl -s --max-time 3 -H "Authorization: Bearer $SECRET" \
        "$API/proxies/$(urlencode "$1")" | grep -oE '"now":"[^"]+"' | cut -d'"' -f4
}
set_group() {
    curl -s --max-time 5 -X PUT -H "Authorization: Bearer $SECRET" \
        -H 'Content-Type: application/json' -d "{\"name\":\"$2\"}" \
        "$API/proxies/$(urlencode "$1")" >/dev/null 2>&1
}

# 节点带宽分 = 最近 4 次测量的中位数（单次噪声大，中位数抗噪）
node_bw() {
    v=$(awk -v n="$1" '
        $1==n {
            m=0
            for(i=2;i<=NF;i++) if($i+0>0) buf[m++]=$i+0
            if(m==0){print 0; exit}
            for(i=0;i<m;i++) for(j=i+1;j<m;j++) if(buf[j]<buf[i]){t=buf[i];buf[i]=buf[j];buf[j]=t}
            if(m%2) printf "%d", buf[int(m/2)]
            else printf "%d", (buf[m/2-1]+buf[m/2])/2
            exit
        }' "$HIST" 2>/dev/null)
    echo "${v:-0}"
}

# 国家带宽分 = 该国节点分最高的前 2 个的平均（活节点不足 2 个 = 0，视为不可用）
country_bw() {
    for node in $(nodes_of "$1"); do
        s=$(node_bw "$node")
        [ -n "$s" ] && [ "$s" -gt 0 ] && echo "$s"
    done | sort -rn | head -2 | awk '{t+=$1;n++} END{if(n>=2) printf "%d", t/2; else print 0}'
}

# 本轮要测的节点：每国取 4 个轮转窗口（窗口起点每轮 +4，2 轮覆盖该国全部节点）
sel_nodes() {
    c=$1; start=$2
    nodes=$(nodes_of "$c")
    cnt=$(echo "$nodes" | grep -c .)
    [ "$cnt" -gt 0 ] || return 0
    win=4; [ "$cnt" -lt "$win" ] && win=$cnt
    rot=$(echo "$nodes" | tail -n +$((start + 1)))
    if [ "$(echo "$rot" | grep -c .)" -lt "$cnt" ]; then
        rot="$rot $(echo "$nodes" | head -n "$start")"
    fi
    echo "$rot" | head -"$win" | tr '\n' ' '
}

# 探测累计流量（机场配额消耗），并入裁决行随日志留痕
probe_note() {
    tb=$(cat "$TOTALF" 2>/dev/null || echo 0)
    echo " | 探测累计 $((tb / 1024 / 1024))MB"
}

# 状态文件（防抖计数 + 每国轮转指针）
[ -f $STATE ] && . $STATE
[ -f $ROTF ] && . $ROTF
PENDING=${PENDING:-}; COUNT=${COUNT:-0}

current=$(get_group "$group")
cur_c=${current%组}

# ── ① 紧急逃生：当前国活节点不足 2 个 → 立刻切到活节点最多的国家（不测带宽，省流量）──
cur_alive=$(alive_count "$cur_c")
if [ "$cur_alive" -lt 2 ]; then
    ba=0; bc=
    for c in $country_list; do
        a=$(alive_count "$c")
        [ "$a" -gt "$ba" ] && { ba=$a; bc=$c; }
    done
    if [ -n "$bc" ] && [ "$ba" -ge 2 ]; then
        set_group "$group" "${bc}组"
        log "$cur_c 活节点 $cur_alive(<2) | 紧急切 $bc(活节点 $ba)$(probe_note)"
        rm -f $STATE
        exit 0
    fi
    log "$cur_c 活节点 $cur_alive(<2) | 两国都不足 2 活节点，保持 $cur_c$(probe_note)"
    exit 0
fi

# ── ② 带宽择优：先测速，再按带宽分裁决 ──
if [ "$BOOT" = 1 ]; then
    # 开机模式：测全部节点（一次性流量，换开机即选到最优国）
    measure=""
    for c in $country_list; do
        measure="$measure $(nodes_of "$c")"
    done
else
    # 常规模式：每国 4 个轮转窗口
    measure=""
    ci=0
    for c in $country_list; do
        ci=$((ci + 1))
        eval "rot=\${ROT$ci:-0}"
        cnt=$(nodes_of "$c" | grep -c .)
        win=4; [ "$cnt" -lt "$win" ] && win=$cnt
        measure="$measure $(sel_nodes "$c" "$rot")"
        eval "ROT$ci=$(( (rot + win) % cnt ))"
    done
    # 轮转指针单独存一份（STATE 会在"保持/切换"分支被清空，指针不能跟着没）
    {
        i=0
        for c in $country_list; do
            i=$((i + 1))
            eval "v=\${ROT$i:-0}"
            echo "ROT$i=$v"
        done
    } > $ROTF
fi
measure=$(echo $measure)

[ -n "$measure" ] || { log "无待测节点，保持 $cur_c"; exit 0; }
/usr/share/miniclash/probe.sh $measure >/dev/null 2>&1

best=; best_s=0; summary=
for c in $country_list; do
    s=$(country_bw "$c")
    summary="$summary $c:${s}B/s,"
    [ "$s" -gt 0 ] && { [ -z "$best" ] || [ "$s" -gt "$best_s" ]; } && { best=$c; best_s=$s; }
done
summary=$(echo "$summary" | sed 's/,$//;s/^ //')
cur_s=$(country_bw "$cur_c")

if [ -z "$best" ]; then
    log "$summary | 无可用国家，保持 $cur_c$(probe_note)"
elif [ "$best" = "$cur_c" ]; then
    rm -f $STATE
    log "$summary | 保持 $cur_c$(probe_note)"
elif [ "$BOOT" = 1 ]; then
    # 开机模式：主组默认成员是任意的，测一次直接进最优国，不走防抖
    set_group "$group" "${best}组"
    log "$summary | 开机直选 $best(${best_s}B/s)$(probe_note)"
    rm -f $STATE
    echo "  → 开机直选 $best"
else
    # 防抖：连续 2 次同一候选 + margin（当前国无数据，或比最优慢 25%）
    [ "$PENDING" = "$best" ] && COUNT=$((COUNT + 1)) || { PENDING=$best; COUNT=1; }
    switched=0
    if [ "$COUNT" -ge 2 ]; then
        margin=0
        if [ "$cur_s" -eq 0 ]; then
            margin=1
        elif [ $((cur_s * 4)) -le $((best_s * 3)) ]; then
            margin=1
        fi
        if [ "$margin" -eq 1 ]; then
            set_group "$group" "${best}组"
            log "$summary | $cur_c(${cur_s}B/s) → $best(${best_s}B/s)$(probe_note)"
            rm -f $STATE
            echo "  → 已切换到 $best"
            switched=1
        fi
    fi
    if [ "$switched" -eq 0 ]; then
        echo "PENDING=$PENDING
COUNT=$COUNT" > $STATE
        log "$summary | 候选 $best $COUNT/2，暂不切换$(probe_note)"
    fi
fi

# 日志轮转：超 512KB 按行原地截断（inode 不变，不切半行，不影响 mihomo 持续 append）
rotate() {
    [ "$(wc -c < "$1")" -gt 524288 ] || return 0
    tail -n "$2" "$1" > "$1.tmp" && cat "$1.tmp" > "$1" && rm -f "$1.tmp"
}
rotate $JLOG 2500  # 裁决历史：每轮约 80B，2500 行 ≈ 8.7 天
rotate $LOG 800    # 内核 warning 量大，800 行 ≈ 200KB
exit 0
