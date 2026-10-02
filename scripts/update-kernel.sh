#!/bin/bash
# 更新 MiniClash 内置 mihomo 内核 + GeoIP 库（在 Mac 上运行）
#
# 用法:
#   ./scripts/update-kernel.sh            仅更新项目内置文件（root/ 下）
#   ./scripts/update-kernel.sh --deploy   更新后同步到路由器并重启服务
#
# 平台: 默认 linux-arm64（mt7981 路由器）；可用 PLATFORM=xxx 覆盖
#
# 下载来源与放置位置（两文件均不入库，见 .gitignore）:
#   内核  https://github.com/MetaCubeX/mihomo/releases/download/<ver>/mihomo-<platform>-<ver>.gz
#         版本号取自 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest
#         → root/usr/bin/mihomo            （路由器 /usr/bin/mihomo）
#   GeoIP https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb
#         → root/etc/miniclash/Country.mmdb（路由器 /etc/miniclash/Country.mmdb，
#                                            另备份 /usr/share/miniclash/etc/miniclash/）
# 版本: 本地内核版本记录在 .mihomo-version（linux 二进制无法在 Mac 上运行 -v，
#       故用标记文件对比；校验走 file 检查 ELF/ARM）
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM="${PLATFORM:-linux-arm64}"
ROOT="$(pwd)/root"
MIHOMO_BIN="$ROOT/usr/bin/mihomo"
MMDB="$ROOT/etc/miniclash/Country.mmdb"
VER_FILE="$(pwd)/.mihomo-version"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 查询 mihomo 最新版本"
# curl 先落盘再解析（避免管道 SIGPIPE 竞态导致偶发失败）
curl -fsSL -o "$TMP/latest.json" https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
    || { echo "错误: 无法获取 mihomo 最新版本" >&2; exit 1; }
latest=$(python3 -c "import json;print(json.load(open('$TMP/latest.json'))['tag_name'])")
cur=$(cat "$VER_FILE" 2>/dev/null || true)
echo "   本地: ${cur:-未知}   最新: $latest"

if [ "$cur" = "$latest" ]; then
    echo "   内核已是最新，跳过"
else
    asset="mihomo-${PLATFORM}-${latest}.gz"
    echo "==> 下载内核 $asset"
    curl -fsSL -o "$TMP/kernel.gz" \
        "https://github.com/MetaCubeX/mihomo/releases/download/${latest}/${asset}"
    gzip -dc "$TMP/kernel.gz" > "$MIHOMO_BIN"
    chmod +x "$MIHOMO_BIN"
    # 平台校验（Mac 不能运行 linux 二进制，用 file 检查 ELF/ARM）+ 体积保护
    file "$MIHOMO_BIN" | grep -qE 'ELF .*ARM' || { echo "错误: 新内核不是 ARM ELF" >&2; exit 1; }
    [ "$(wc -c < "$MIHOMO_BIN")" -ge 1048576 ] || { echo "错误: 新内核过小 (<1MB)" >&2; exit 1; }
    echo "$latest" > "$VER_FILE"
    echo "   内核已更新 → $latest ($(du -h "$MIHOMO_BIN" | cut -f1))"
fi

echo "==> 下载最新 GeoIP 库 (country.mmdb)"
curl -fsSL -o "$TMP/Country.mmdb" \
    "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb"
# 损坏保护：GeoIP 库必须 > 1MB（与 ConfigManager 同规则）
[ "$(wc -c < "$TMP/Country.mmdb")" -ge 1048576 ] || { echo "错误: 下载的 mmdb 异常 (<1MB)，已取消" >&2; exit 1; }
# 校验 MD5 防 CDN 返回损坏内容（首次部署无旧校验则跳过）
if [ -f "$MMDB" ]; then
    old_md5=$(md5sum "$MMDB" 2>/dev/null | cut -d' ' -f1)
    new_md5=$(md5sum "$TMP/Country.mmdb" 2>/dev/null | cut -d' ' -f1)
    [ "$old_md5" = "$new_md5" ] && { echo "   GeoIP 已是最新，跳过"; rm -f "$TMP/Country.mmdb"; } || {
        mv "$TMP/Country.mmdb" "$MMDB"
        echo "   GeoIP 已更新 ($(du -h "$MMDB" | cut -f1), md5=$new_md5)"
    }
else
    mv "$TMP/Country.mmdb" "$MMDB"
    echo "   GeoIP 已更新 ($(du -h "$MMDB" | cut -f1))"
fi

if [ "${1:-}" = "--deploy" ]; then
    echo "==> 同步到路由器并重启服务"
    ./scripts/install.sh
    ssh luyou '/etc/init.d/miniclash restart && sleep 1 && /etc/init.d/miniclash status'
    echo "==> 部署完成"
else
    echo "==> 项目已更新。部署到路由器：./scripts/install.sh（或加 --deploy 一步完成）"
fi
