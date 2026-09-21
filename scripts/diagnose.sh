#!/bin/bash
# 用 TypeSafe Jev 对 mihomo 日志做智能分诊：节点故障 / 故障类型 / 健康度
# 用法: ./scripts/diagnose.sh [主机别名，默认 luyou]
# 依赖: TYPESAFE_API_KEY（.zshrc）、jq
set -e

ROUTER="${1:-luyou}"

[ -n "$TYPESAFE_API_KEY" ] || { echo "未设置 TYPESAFE_API_KEY"; exit 1; }
command -v jq >/dev/null || { echo "需要 jq（brew install jq）"; exit 1; }

# 取近期 warning/error，脱敏节点 IP 与 LAN 客户端地址后再出网
LOG=$(ssh "$ROUTER" 'tail -2000 /etc/miniclash/miniclash.log | grep -iE "level=warning|level=error" | tail -45' \
    | sed -E 's/dial tcp [0-9.]+:[0-9]+/dial tcp <node-ip>/g; s/192\.168\.[0-9]+\.[0-9]+/<lan-client>/g')

if [ -z "$LOG" ]; then
    echo "近期无 warning/error 日志，代理看起来很健康"
    exit 0
fi

RESP=$(jq -n --arg log "$LOG" '{
    model: "jev-latest",
    state: {
        system: "MiniClash 透明代理，mihomo 内核，fallback 主组默认节点 + 备用 url-test 池",
        warning_log_lines: $log
    },
    questions: {
        node_fault_present: {
            type: "noul",
            instructions: "根据 warning_log_lines，代理节点侧是否存在真实的连接故障？判据：多条 dial 失败且持续数小时即yes；仅零星几条、可能是单次客户端取消则no。DIRECT 出站的 i/o timeout 是局域网内直连失败，与代理节点无关。"
        },
        primary_fault_type: {
            type: "choice",
            instructions: "warning_log_lines 中代理拨号失败的主要故障类型？failed to create session: EOF 是隧道协议会话建立即断开；context deadline exceeded 与 dial tcp i/o timeout 是节点不可达/超时。",
            criteria: {
                node_unreachable: "以 i/o timeout、context deadline exceeded 为主，节点网络不可达",
                tunnel_protocol_eof: "以 failed to create session: EOF 为主，隧道会话被节点断开",
                mixed_node_side: "超时与 EOF 大量并存，均为节点侧问题，无法归为单一类",
                no_fault: "没有代理侧故障"
            }
        },
        health_level: {
            type: "score",
            instructions: "综合失败频率、持续时间、涉及服务面评估代理整体健康度。",
            criteria: [
                "健康：无失败或极个别偶发",
                "轻微噪声：少量失败，主流服务正常",
                "明显劣化：失败频繁且持续数小时，多个服务受影响",
                "严重中断：绝大多数海外连接失败，代理基本不可用"
            ]
        }
    }
}' | curl -sS https://api.typesafe.ai/v1/systemone \
    -H "Authorization: Bearer $TYPESAFE_API_KEY" \
    -H "Content-Type: application/json" \
    -d @-)

echo "$RESP" | jq -r '
    .answers as $a |
    "节点故障: \(if $a.node_fault_present.noul >= 0.5 then "是" else "否" end) (\(($a.node_fault_present.noul * 100) | round)%)",
    "故障类型: \($a.primary_fault_type.choice)（置信度 \((($a.primary_fault_type.confidence // 0) * 100) | round)%）",
    "健康度:   \($a.health_level.score | . * 10 | round / 10)/3（级别 \($a.health_level.probabilities | to_entries | max_by(.value) | .key | tonumber)）"
'
echo
echo "健康度级别: 0健康 1轻微噪声 2明显劣化 3严重中断"
