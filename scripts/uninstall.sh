#!/bin/bash
# Mac → 路由器卸载脚本（彻底移除 MiniClash 及运行时数据）
# 用法: ./scripts/uninstall.sh [主机别名，默认 luyou]
set -e

ROUTER="${1:-luyou}"

echo "==> 将删除以下内容："
echo "    /etc/init.d/miniclash        启停脚本"
echo "    /etc/rc.d/*miniclash         开机自启项"
echo "    /etc/config/miniclash        配置"
echo "    /usr/bin/mihomo              内核二进制"
echo "    /etc/miniclash/              运行时数据（订阅/配置/日志/Country.mmdb）"
echo "    /usr/share/miniclash/        judge.sh 与 GeoIP 备份"
echo "    crontab judge.sh 定时裁决条目"
echo "    LuCI 界面文件 (controller/view)"
read -r -p "确认卸载？(y/N) " ans
[ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消"; exit 1; }

ssh "$ROUTER" '
echo "==> 停止服务"
/etc/init.d/miniclash stop 2>/dev/null
/etc/init.d/miniclash disable 2>/dev/null

echo "==> 删除文件"
rm -f /etc/init.d/miniclash
rm -f /etc/rc.d/*miniclash
rm -f /etc/config/miniclash
rm -f /usr/bin/mihomo
rm -rf /etc/miniclash
rm -rf /usr/share/miniclash
sed -i '/judge\.sh/d' /etc/crontabs/root 2>/dev/null
/etc/init.d/cron restart 2>/dev/null
rm -f /usr/lib/lua/luci/controller/miniclash.lua
rm -rf /usr/lib/lua/luci/view/miniclash
rm -f /usr/lib/lua/luci/model/cbi/miniclash.lua

echo "==> 重建 LuCI 索引"
rm -f /tmp/luci-indexcache* 2>/dev/null
rm -rf /tmp/luci-modulecache 2>/dev/null

echo "==> 卸载完成"
'
