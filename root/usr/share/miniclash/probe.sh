#!/bin/sh
# probe — 按节点名实测真实下载带宽（judge 择优判据的底座）
#
# 为什么不能用 mihomo 的 delay API 测速：
#   /proxies/<name>/delay 测的是建连+首字节(TTFB)，不随响应体大小增长
#   （2026-10-24 实测：同一节点同一 URL，1MB 与 8MB 耗时相同）→ 它测不出带宽。
#   而延迟与带宽并不同向（2026-10-24 实测：日本组真实下载快 41%，延迟却略高于新加坡），
#   按延迟选会稳定选到慢线路。
#
# 怎么测"某个"节点：
#   配置里给每个节点开一个本地 HTTP listener（listeners 段，proxy: 字段钉死该节点，
#   init.d gen_config 生成）。经该端口下载，得到的就是那个节点的真实下载速度，
#   且不干扰线上流量（独立端口、独立连接）。
#   端口→节点映射直接读 config.yaml 的 listeners 段——配置是唯一事实来源，不另建映射表。
#
# 测法要点（均为 2026-10-24 / 10-25 实测结论）：
#   ① 串行测，不并发。16 路并发会互相抢带宽，排序完全失真
#      （同一批节点并发测日本3第一(174K)、串行测日本1第一(226K)）。
#   ② 样本 1MB（实际取到目标全量 ~926KB）。样本太小则握手时间占比过高，测的是握手不是带宽。
#      2026-10-25 实测：同一批节点 256KB 测出 210~240K，全量样本测出 700~1100K（差 3~5 倍）；
#      更关键的是**排序会翻转**——256KB 下新加坡领先(238K vs 日本 224K)，
#      1MB 下日本前两名中位数 915K 反而高于新加坡 855K，
#      按 256KB 裁决会稳定选到慢线路。故样本提到 1MB。
#   ③ 单次采样噪声可达 55%（日本3 连测 133K/180K/206K）→ 历史取中位数抗噪。
#   ④ 1MB 样本耗时更长，超时放宽到 40s（1MB@25KB/s 需 42s，慢节点允许截断取已下字节）。
#
# 用法: probe.sh <节点名> [<节点名>...]
# 输出: 每行 "节点名|字节每秒"（失败为 0）
# 副作用:
#   历史文件 $HIST：每行 "节点名 v1 v2 v3 v4"（最近 4 次测量值，最新在后）→ judge 取中位数
#   累计流量 $TOTAL：探测消耗的总字节数 → 巡检/流量核算

WORKDIR=/etc/miniclash
CONFIG=$WORKDIR/config.yaml
HIST=/tmp/miniclash_bandwidth.state
TOTAL=/tmp/miniclash_bandwidth.total

# 探测目标：GitHub raw CDN 上的稳定小文件
#   ① 是真实业务目标（日常就是从 GitHub 拉东西）
#   ② 服务端支持 Range，-r 只取前 1MB（目标 MAINTAINERS 实际 948,847 字节，
#      Range 请求会取到全量 ~926KB——这已是该 URL 能给的最大样本）
#   ③ 不用 codeload 的大 tarball——并发拉会触发 GitHub 429 限流
#      （2026-10-24 实测 16 并发拉 tarball 全部 429）
#   ④ 实测其排序与真实大文件下载速度同向，可作为带宽代理
PROBE_URL='https://raw.githubusercontent.com/torvalds/linux/master/MAINTAINERS'
PROBE_BYTES=1048576    # 1MB（2026-10-25 起；256KB 会把握手当带宽，国家排序会翻转）
PROBE_TIMEOUT=40       # 单节点超时（秒）

[ -r "$CONFIG" ] || exit 1
[ $# -gt 0 ] || exit 1

# 从 config.yaml 的 listeners 段解析 "端口 节点名" 映射
# listeners 行形如：  - { name: probe-日本1, type: http, port: 9100, listen: 127.0.0.1, proxy: '日本1' }
parse_map() {
    awk '
        /^listeners:/ { inl=1; next }
        inl && /^[a-z-]+:/ { inl=0 }
        inl && /port:/ {
            port=$0; sub(/.*port: /,"",port); sub(/,.*/,"",port)
            node=$0; sub(/.*proxy: /,"",node); gsub(/[\047"]/,"",node); sub(/ *}.*/,"",node)
            if (port != "" && node != "") print port, node
        }
    ' "$CONFIG"
}

MAP=$(parse_map)
[ -n "$MAP" ] || exit 1

OUT=/tmp/miniclash_probe.$$
: > "$OUT"
total=0

# 串行逐个测：经钉死端口下载前 1MB，输出字节每秒
# OUT 内部用空格分隔（供历史合并按字段取），对外输出再转成 "节点|字节每秒"
for n in "$@"; do
    port=$(echo "$MAP" | awk -v n="$n" '$2==n {print $1; exit}')
    if [ -z "$port" ]; then
        echo "$n 0" >> "$OUT"
        continue
    fi
    r=$(curl -s -m "$PROBE_TIMEOUT" -x "http://127.0.0.1:$port" \
        -r "0-$((PROBE_BYTES - 1))" -o /dev/null \
        -w '%{size_download} %{speed_download}' -L "$PROBE_URL" 2>/dev/null)
    size=$(echo "$r" | cut -d' ' -f1)
    speed=$(echo "$r" | cut -d' ' -f2)
    if [ -z "$size" ] || [ "$size" -eq 0 ] 2>/dev/null; then
        echo "$n 0" >> "$OUT"
        continue
    fi
    total=$((total + size))
    echo "$n ${speed:-0}" >> "$OUT"
done

awk '{print $1"|"$2}' "$OUT"

# 历史合并：每节点只留最近 4 次测量值（旧的最近 3 次 + 本次新值）
# 注：$OUT 必须非空才能做 FNR==NR 切换（awk 空文件会把历史误当新值）
[ -f "$HIST" ] || : > "$HIST"
if [ -s "$OUT" ]; then
awk -v OFS=' ' '
    FNR==NR { v[$1]=$2; next }
    {
        if ($1 in v) {
            m=0
            for(i=NF;i>=2 && m<3;i--) buf[m++]=$i
            out=$1
            for(i=m-1;i>=0;i--) out=out OFS buf[i]
            print out, v[$1]
            delete v[$1]
        } else print
    }
    END { for (n in v) print n, v[n] }
' "$OUT" "$HIST" > "$HIST.tmp" 2>/dev/null && mv "$HIST.tmp" "$HIST"
fi

# 累计探测流量（供巡检核算机场配额消耗）
old=$(cat "$TOTAL" 2>/dev/null || echo 0)
echo $((old + total)) > "$TOTAL"

rm -f "$OUT"
exit 0
