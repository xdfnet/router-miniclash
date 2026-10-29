#!/bin/sh
# guard — 故障自愈：主组当前节点不通时，切到带宽排名里第一个活的节点
#
# 为什么需要它（2026-10-29 决策）：
#   主组改为单池 select 后，内核不再有 url-test 组做兜底自愈——url-test 按延迟选节点，
#   与本项目的带宽判据冲突（实测它常选中组内带宽最差的节点），而且它的 alive 只在组内维护。
#   所以「谁来当出口」这件事从头到尾自己管：judge 按真实带宽选节点，guard 负责节点挂掉时切换。
#
# 探活方式：mihomo 的 delay API —— 内核用指定节点发一次真实请求，通=活。
#   流量代价极小（generate_204 几 KB/次），每 check_interval 秒一次。
#   与 probe.sh 的测速 URL 刻意不同（probe 打 raw.githubusercontent 的 1MB 正文）：
#   probe 测带宽、guard 测活着，两者互不污染对方的读数。
#
# 排名文件 $RANK：judge 每轮按带宽降序写入节点名列表（一行一个）。guard 按序找第一个活的。
#
# 用法: guard.sh          # 检查一次，必要时切换（幂等，可反复调用）
WORKDIR=/etc/miniclash
SECRET=$(cat $WORKDIR/api_secret 2>/dev/null)
API=http://127.0.0.1:9090
RANK=/tmp/miniclash_rank
LOG=$WORKDIR/guard.log
GROUP=$(uci -q get miniclash.core.group 2>/dev/null); GROUP=${GROUP:-自动优选}
ALIVE_URL='https://github.com/generate_204'
ALIVE_TIMEOUT=5000      # 单节点探活超时（毫秒）
MAX_CANDIDATES=5        # 最多试几个备选（每个最多等 ALIVE_TIMEOUT）

[ -n "$SECRET" ] || exit 0

log() { echo "[$(date '+%F %T')] [guard] $*" >> $LOG 2>/dev/null; }

# URL 编码（逐字节；中文 UTF-8 按字节编码正是所需）
urlencode() {
    s=$1; out=; c=; i=1
    while [ $i -le ${#s} ]; do
        c=$(expr substr "$s" $i 1)
        case "$c" in
            [a-zA-Z0-9.~_-]) out=$out$c ;;
            *) out=$out$(printf '%%%02X' "'$c") ;;
        esac
        i=$((i + 1))
    done
    echo "$out"
}

# 该节点是否活着（内核经它发一次请求）
alive_of() {
    curl -s --max-time 8 -H "Authorization: Bearer $SECRET" \
        "$API/proxies/$(urlencode "$1")/delay?timeout=$ALIVE_TIMEOUT&url=$(urlencode "$ALIVE_URL")" \
        2>/dev/null | grep -q '"delay":'
}

get_now() {
    curl -s --max-time 3 -H "Authorization: Bearer $SECRET" \
        "$API/proxies/$(urlencode "$1")" 2>/dev/null | grep -oE '"now":"[^"]+"' | cut -d'"' -f4
}

set_group() {
    curl -s --max-time 5 -X PUT -H "Authorization: Bearer $SECRET" \
        -H 'Content-Type: application/json' -d "{\"name\":\"$2\"}" \
        "$API/proxies/$(urlencode "$1")" >/dev/null 2>&1
}

now=$(get_now "$GROUP")
[ -n "$now" ] || exit 0
alive_of "$now" && exit 0

# 当前节点不通 → 按带宽排名找备选
log "当前节点 $now 不通，查找备选"
tried=0
for n in $(cat $RANK 2>/dev/null); do
    [ "$n" = "$now" ] && continue
    tried=$((tried + 1))
    [ $tried -gt $MAX_CANDIDATES ] && break
    if alive_of "$n"; then
        set_group "$GROUP" "$n"
        log "已切到 $n"
        exit 0
    fi
done
log "排名前 $tried 个备选均不通，保持 $now"
exit 0
