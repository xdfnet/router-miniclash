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
# 探活 URL（两个）。为什么不用 github.com/generate_204：
#   2026-11-16 实测该 URL 在 10 秒口径下 16 个节点超时 4 个，20 秒口径仍有 4 个报错
#   （GitHub 那边 generate_204 已不保证 204），单靠它会把活节点判死。
# 为什么必须用两个：单 URL 采样噪声大——同一批 16 节点同一时刻，
#   github 超时 4 个、gstatic 超时 5 个，**失败的还不是同一批**（日本3 只挂 gstatic、
#   日本7 只挂 github）。单 URL 判死 = 每分钟切一次节点（2026-11-16 当天 guard 记了 606 条、
#   每次切换都断连，X 内容加载不出来就是这么来的）。
#   两个都失败才算不通——同一批数据下误判 0 个。
ALIVE_URLS='https://www.gstatic.com/generate_204
http://cp.cloudflare.com/generate_204'
ALIVE_TIMEOUT=15000     # 单节点探活超时（毫秒）
# 2026-11-02 实测：节点握手延迟 0.6~3.5 秒，5 秒口径下 16 个节点有 2 个直接超时
# （15 秒口径 1.96s / 2.22s 就通）；探活偏紧 → guard 每天误判 65~79 次、每 20~30 分钟
# 切一次节点（每次切换都断连）。放宽到 10 秒后误判大幅下降，真挂节点仍由 watchdog
# 每 60 秒一轮发现（多等 5 秒可接受）。
# 2026-11-16：光放宽超时还不够——线路噪声让单次采样仍有 30% 误判，
#   故再加"连续两轮都失败才算不通"（单轮失败只记账，不切换）。
CONFIRM_ROUNDS=2       # 连续几轮探活失败才判定当前节点不通
FAILFILE=/tmp/miniclash_guard_fail   # 记录 "<失败轮数> <节点名>"
MAX_CANDIDATES=3        # 最多试几个备选（每个最多等 2×ALIVE_TIMEOUT）

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

# 该节点是否活着（内核经它发一次请求；两个探活 URL 任一通过即算活）
alive_of() {
    for u in $ALIVE_URLS; do
        curl -s --max-time 20 -H "Authorization: Bearer $SECRET" \
            "$API/proxies/$(urlencode "$1")/delay?timeout=$ALIVE_TIMEOUT&url=$(urlencode "$u")" \
            2>/dev/null | grep -q '"delay":' && return 0
    done
    return 1
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
if alive_of "$now"; then
    echo "0 $now" > "$FAILFILE" 2>/dev/null
    exit 0
fi

# 本轮探活失败 → 记账；连续 CONFIRM_ROUNDS 轮都失败才判定节点不通并切换
# （单轮失败只是线路抖动，切了反而断连——2026-11-16 之前的乱切就是这么来的）
cnt=$(awk -v n="$now" '$1==n {print $2; exit}' "$FAILFILE" 2>/dev/null)
case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
cnt=$((cnt + 1))
echo "$cnt $now" > "$FAILFILE" 2>/dev/null
[ "$cnt" -lt "$CONFIRM_ROUNDS" ] && exit 0

# 当前节点确认不通 → 按带宽排名找备选
log "当前节点 $now 连续 $cnt 轮探活失败，查找备选"
tried=0
for n in $(cat $RANK 2>/dev/null); do
    [ "$n" = "$now" ] && continue
    tried=$((tried + 1))
    [ $tried -gt $MAX_CANDIDATES ] && break
    if alive_of "$n"; then
        set_group "$GROUP" "$n"
        echo "0 $n" > "$FAILFILE" 2>/dev/null
        log "已切到 $n"
        exit 0
    fi
done
log "排名前 $tried 个备选均不通，保持 $now"
exit 0
