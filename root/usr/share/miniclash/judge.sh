#!/bin/sh
# judge — 节点自动裁决（cron 每 15 分钟）
#
# 判据是"真实下载带宽"，不是延迟。理由（2026-10-24 实测）：
#   ① mihomo 的 delay API 只测建连+首字节(TTFB)，不随响应体大小增长，
#      同一节点同一 URL 1MB 与 8MB 耗时相同 → 它测不出带宽；
#   ② 延迟与带宽并不同向：日本组真实下载快 41%，延迟却略高于新加坡。
#      按延迟选会稳定选到慢线路。
#   带宽由 probe.sh 实测（每个节点一个 pinned listener，下载真实内容测速）。
#
# 单池结构（2026-10-29 决策，取代原先的「主组 + 每国 url-test 组」两层）：
#   主组「自动优选」是 select，成员就是全部节点。judge 按带宽排名选**具体节点** PUT 进去，
#   不再有"国家"这一层，也不再让内核 url-test 参与选择（它按延迟选，与带宽判据冲突）。
#   节点挂掉时的切换由 guard.sh 负责（探活 + 切到排名里第一个活的）。
#
# 择优规则：节点分 = 该节点最近 4 次测量的中位数（单次噪声可达 55%，中位数抗噪）；
#   连续 2 次同一候选 + 领先 25% 才切 —— 双确认 + margin，防打地鼠横跳。
#
# 流量预算：每轮测全部 16 个节点 × 1MB ≈ 16MB/轮，15 分钟一轮 ≈ ~1.5GB/天
#   （占剩余配额约 1%；测全量是为了每个节点的读数都是新鲜的，牺牲这点流量换判断准确）。
#   样本从 256KB 提到 1MB 的原因：256KB 把握手当带宽且会让排序翻转（2026-10-25 实测）。
#   测速必须串行（并发互抢带宽会毁掉排序，2026-10-24 实测）。
#
# BOOT=1：开机/重启模式，测一次直接进最优节点（绕过双确认），由 init.d start() 调用。

WORKDIR=/etc/miniclash
STATE=/tmp/miniclash_judge.state      # 防抖计数（保持/切换成功时清空）
HIST=/tmp/miniclash_bandwidth.state
TOTALF=/tmp/miniclash_bandwidth.total
RANK=/tmp/miniclash_rank              # 带宽排名（节点名，一行一个，降序）——guard.sh 按序找备选
JLOG=$WORKDIR/judge.log     # judge 裁决历史（独立文件，不被内核 warning 淹没）
LOG=$WORKDIR/miniclash.log  # 内核 warning + init.d 事件
SECRET=$(cat $WORKDIR/api_secret 2>/dev/null)
API=http://127.0.0.1:9090

get() { uci -q get miniclash.core.$1 2>/dev/null; }
log() { echo "[$(date '+%F %T')] [judge] $*" >> $JLOG; }

# 停用 / 手动 stop 时静默退出
[ "$(get enabled)" = "1" ] || exit 0
group=$(get group); group=${group:-自动优选}

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

# 探测累计流量（机场配额消耗），并入裁决行随日志留痕
probe_note() {
    tb=$(cat "$TOTALF" 2>/dev/null || echo 0)
    echo " | 探测累计 $((tb / 1024 / 1024))MB"
}

# 状态文件（防抖计数）
[ -f $STATE ] && . $STATE
PENDING=${PENDING:-}; COUNT=${COUNT:-0}

# ── ① 故障自愈（免费、即时）：当前节点不通就切到排名里第一个活的 ──
# 用上一轮的排名文件；judge 每 15 分钟才跑，故障切换交给 watchdog 每 60 秒调 guard.sh
# （此处再调一次是兜底：万一 watchdog 没起来，至少 judge 轮次能救回来）
/usr/share/miniclash/guard.sh >/dev/null 2>&1

current=$(get_group "$group")

# ── ② 带宽择优：测全部节点，按带宽排名选具体节点 ──
[ -n "$all_names" ] || { log "无节点，保持 $current"; exit 0; }
/usr/share/miniclash/probe.sh $all_names >/dev/null 2>&1

# 排名（按带宽分降序；0 分的排在最后，作为"慢但可能活着"的兜底）
ranking=$(for n in $all_names; do echo "$(node_bw "$n") $n"; done | sort -rn | awk '{print $2}')
echo "$ranking" > $RANK

best=; best_s=0
for n in $all_names; do
    s=$(node_bw "$n")
    [ "$s" -gt 0 ] && { [ -z "$best" ] || [ "$s" -gt "$best_s" ]; } && { best=$n; best_s=$s; }
done
# 摘要只留前三名 + 当前节点（16 个全列太长，日志一行塞不下）
top3=$(for n in $all_names; do echo "$(node_bw "$n") $n"; done | sort -rn | head -3 | awk '{printf "%s:%sB/s ", $2, $1}')
cur_s=$(node_bw "$current")
summary="Top $top3| 当前 $current:${cur_s}B/s"

if [ -z "$best" ]; then
    log "$summary | 无可用节点，保持 $current$(probe_note)"
elif [ "$best" = "$current" ]; then
    rm -f $STATE
    log "$summary | 保持 $current(${cur_s}B/s)$(probe_note)"
elif [ "$BOOT" = 1 ]; then
    # 开机模式：主组默认成员是任意的，测一次直接进最优节点，不走防抖
    set_group "$group" "$best"
    log "$summary | 开机直选 $best(${best_s}B/s)$(probe_note)"
    rm -f $STATE
    echo "  → 开机直选 $best"
else
    # 快速通道：当前节点明显劣化（带宽掉到最优的 1/3 以下）→ 单轮即切，不等双确认。
    # 死节点由 guard.sh 处理（60s 粒度）；"慢但没死"只有测速能看出来，
    # 等双确认要 30 分钟——而"用最快的节点"正是本方案的核心承诺。
    if [ "$cur_s" -gt 0 ] && [ "$best_s" -gt 0 ] && [ $((cur_s * 3)) -le $((best_s)) ]; then
        set_group "$group" "$best"
        log "$summary | 当前节点劣化 $current(${cur_s}B/s) → 快切 $best(${best_s}B/s)$(probe_note)"
        rm -f $STATE
        echo "  → 当前节点劣化，快速切到 $best"
    else
        # 防抖：连续 2 次同一候选 + margin（当前节点无数据，或比最优慢 25%）
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
                set_group "$group" "$best"
                log "$summary | $current(${cur_s}B/s) → $best(${best_s}B/s)$(probe_note)"
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
fi

# 日志轮转：超 512KB 按行原地截断（inode 不变，不切半行，不影响 mihomo 持续 append）
rotate() {
    [ "$(wc -c < "$1")" -gt 524288 ] || return 0
    tail -n "$2" "$1" > "$1.tmp" && cat "$1.tmp" > "$1" && rm -f "$1.tmp"
}
rotate $JLOG 2500  # 裁决历史：每轮约 160B，2500 行 ≈ 8.7 天
rotate $LOG 800    # 内核 warning 量大，800 行 ≈ 200KB
exit 0
