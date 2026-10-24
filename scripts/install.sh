#!/bin/bash
# Mac → 路由器安装脚本（tar over ssh，路由器无需装 rsync）
# 用法: ./scripts/install.sh [主机别名，默认 luyou]
set -e

ROUTER="${1:-luyou}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 内核 / GeoIP 库不入库（见 .gitignore），首次部署或新克隆后需按需下载
if [ ! -f "$ROOT/root/usr/bin/mihomo" ] || [ ! -f "$ROOT/root/etc/miniclash/Country.mmdb" ] || [ ! -f "$ROOT/root/etc/miniclash/cn.mrs" ]; then
    echo "==> 本地缺少内核/GeoIP 库，先下载"
    "$ROOT/scripts/update-kernel.sh"
fi

echo "==> 同步系统文件 (root/ → /，绝不覆盖 UCI 配置)"
FILES=$(cd "$ROOT/root" && find . -type f ! -path './etc/config/*' ! -name '.DS_Store')
tar -C "$ROOT/root" -czf - $FILES | ssh "$ROUTER" 'tar -C / -xzf -'
# GeoIP 库额外备份到 /usr/share/miniclash/ 防 F2FS 丢文件（mmdb 部署到 /etc/miniclash/ 与 workdir 同路径，F2FS 丢文件时无法恢复）
ssh "$ROUTER" 'mkdir -p /usr/share/miniclash/etc/miniclash && cp -f /etc/miniclash/Country.mmdb /usr/share/miniclash/etc/miniclash/Country.mmdb 2>/dev/null; true'

echo "==> 首次部署时安装配置模板（已有配置则保留现场）"
ssh "$ROUTER" 'test -f /etc/config/miniclash' || scp "$ROOT/root/etc/config/miniclash" "$ROUTER:/etc/config/miniclash"

echo "==> 设置可执行权限"
ssh "$ROUTER" 'chmod +x /etc/init.d/miniclash /usr/bin/mihomo /usr/share/miniclash/meter.sh /usr/share/miniclash/judge.sh /usr/share/miniclash/probe.sh 2>/dev/null; true'
# 确认 GeoIP 备份存在
ssh "$ROUTER" 'ls -lh /usr/share/miniclash/etc/miniclash/Country.mmdb 2>/dev/null || echo "   注意: GeoIP 备份不存在"; true'

echo "==> 清理废弃 LuCI 界面（纯配置方案不再需要界面）"
ssh "$ROUTER" 'rm -f /usr/lib/lua/luci/controller/miniclash.lua; rm -rf /usr/lib/lua/luci/view/miniclash; rm -f /usr/lib/lua/luci/model/cbi/miniclash.lua; rm -f /tmp/luci-indexcache* 2>/dev/null; rm -rf /tmp/luci-modulecache 2>/dev/null; true'

echo "==> 拉取订阅并启动（本地过滤日本/新加坡节点后上传）"
"$ROOT/scripts/update-subscribe.sh" "$ROUTER"

echo "==> 安装完成"
