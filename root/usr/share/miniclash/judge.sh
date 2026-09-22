#!/bin/sh
# judge — 跨国线路自动裁决（cron 每 5 分钟）
# 对每国节点实测 github + google 双目标；国家分 = 最快 2 个活节点延迟均值；
# 连续 2 次别国领先 20% 才经 API 切换 select 主组——双确认 + margin，防打地鼠横跳。

WORKDIR=/etc/miniclash
STATE=/tmp/miniclash_judge.state
LOG=$WORKDIR/miniclash.log
SECRET=$(cat $WORKDIR/api_secret 2>/dev/null)
API=http://127.0.0.1:9090

T1='https://github.com/generate_204'
T2='https://www.google.com/generate_204'

get() { uci -q get miniclash.core.$1 2>/dev/null; }
log() { echo "[$(date '+%F %T')] [judge] $*" >> $LOG; }

# 停用 / 手动 stop 时静默退出
[ "$(get enabled)" = "1" ] || exit 0
group=$(get group); group=${group:-自动优选}
# 参与裁决的国家（有序，第 1 个为 select 默认；单一场景固化）
countries=新加坡,日本

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

# probe <节点> <目标> → 延迟 ms；失败空串
probe() {
    curl -s --max-time 6 -H "Authorization: Bearer $SECRET" \
        "$API/proxies/$(urlencode "$1")/delay?url=$(urlencode "$2")&timeout=5000" \
        | grep -oE '"delay":[0-9]+' | cut -d: -f2
}

# 节点名归集（与 init.d gen_config 同一规则）
all_names=$(awk '/^proxies:/{p=1;next}/^[a-z-]+:/{p=0}p' $WORKDIR/subscribe.yaml \
    | grep -oE "name: [^,}]+" | sed "s/name: //; s/^'//; s/'$//")

TMPD=/tmp/miniclash_judge.$$
mkdir -p $TMPD
trap 'rm -rf $TMPD' EXIT

# 每节点并发双目标探测，结果: 国家|节点|github延迟|google延迟（X=失败）
for c in $(echo "$countries" | tr ',' ' '); do
    for n in $all_names; do
        case "$n" in "$c"*)
            ( d1=$(probe "$n" "$T1"); d2=$(probe "$n" "$T2")
              echo "$c|$n|${d1:-X}|${d2:-X}" >> $TMPD/results ) &
        ;; esac
    done
done
wait

# score <国家> → 最快 2 活节点延迟均值；活节点不足 2 个 = X（不可用）
score() {
    awk -F'|' -v c="$1" '$1==c && $3!="X" && $4!="X"{print $3}' $TMPD/results \
        | sort -n | head -2 \
        | awk '{s+=$1;n++} END{if(n>=2) printf "%d",s/2; else print "X"}'
}

# 当前国家（select now = 国家组名，去掉"组"）
current=$(curl -s --max-time 3 -H "Authorization: Bearer $SECRET" \
    "$API/proxies/$(urlencode "$group")" | grep -oE '"now":"[^"]+"' | cut -d'"' -f4)
cur_c=${current%组}
cur_s=$(score "$cur_c")

# best = 分数最低的可用国家；summary 汇总各国分数供每次落日志
best=; best_s=; summary=
for c in $(echo "$countries" | tr ',' ' '); do
    s=$(score "$c")
    echo "  $c: ${s}ms"
    summary="$summary $c:${s}ms,"
    [ "$s" != X ] && { [ -z "$best_s" ] || [ "$s" -lt "$best_s" ]; } && { best=$c; best_s=$s; }
done
summary=$(echo "$summary" | sed 's/,$//;s/^ //')

if [ -z "$best" ]; then
    rm -f $STATE
    log "$summary | 无可用国家，保持 $cur_c"
elif [ "$best" = "$cur_c" ]; then
    rm -f $STATE
    log "$summary | 保持 $cur_c"
else
    # 防抖：连续 2 次同一候选 + margin（current 不可用，或比 best 慢 20%）
    PENDING=; COUNT=0
    [ -f $STATE ] && . $STATE
    [ "$PENDING" = "$best" ] && COUNT=$((COUNT+1)) || { PENDING=$best; COUNT=1; }

    switched=0
    if [ $COUNT -ge 2 ]; then
        margin=0
        if [ "$cur_s" = X ]; then margin=1
        elif [ $((cur_s*10)) -ge $((best_s*12)) ]; then margin=1; fi
        if [ $margin -eq 1 ]; then
            curl -s -X PUT --max-time 5 \
                -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
                -d "{\"name\":\"${best}组\"}" "$API/proxies/$(urlencode "$group")"
            log "$summary | $cur_c(${cur_s}ms) → $best(${best_s}ms)"
            rm -f $STATE
            echo "  → 已切换到 $best"
            switched=1
        fi
    fi
    if [ $switched -eq 0 ]; then
        echo "PENDING=$PENDING
COUNT=$COUNT" > $STATE
        log "$summary | 候选 $best $COUNT/2，暂不切换"
        echo "  → 候选 $best，连续确认 $COUNT/2，暂不切换"
    fi
fi

# 日志超 512KB 原地截断保留最后 200KB（inode 不变，mihomo 持续 append 不受影响）
[ "$(wc -c < $LOG)" -gt 524288 ] && \
    tail -c 204800 $LOG > $LOG.tmp && cat $LOG.tmp > $LOG && rm -f $LOG.tmp
exit 0
