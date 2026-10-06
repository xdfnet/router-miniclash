#!/bin/sh
# 每分钟采样 mihomo 实时连接，按连接累计真实字节增量到大分区。
# 用途：分析"哪些域名/APP 走了代理、烧了多少流量"，揪出本可直连却被代理的流量。
# 只统计采样时刻仍存活的连接（视频/下载/更新等长连接必被抓，正是流量大头）。
# 任何异常都静默退出，绝不影响代理本身。

DATADIR=/mnt/mmcblk0p7
DIR=$DATADIR/logs/miniclash
STATE=/tmp/miniclash-meter.state
TMPSTATE=/tmp/miniclash-meter.state.new
API=http://127.0.0.1:9090/connections
SECRET_FILE=/etc/miniclash/api_secret
KEEP=32

# 大分区未挂载则尝试挂载；仍不可写就放弃本轮
mountpoint -q $DATADIR 2>/dev/null || mount $DATADIR 2>/dev/null
mkdir -p $DIR 2>/dev/null || exit 0
touch $DIR/.wtest 2>/dev/null || exit 0
rm -f $DIR/.wtest

[ -r "$SECRET_FILE" ] || exit 0
SECRET=$(cat "$SECRET_FILE")
JSON=$(curl -s -m 10 -H "Authorization: Bearer $SECRET" "$API")
# 服务未运行 / 无连接时不动 state
echo "$JSON" | grep -q '"id"' || exit 0

CSV=$DIR/meter-$(date +%Y%m%d).csv
EPOCH=$(date +%s)

echo "$JSON" | tr '\n' ' ' | awk -v csv="$CSV" -v st="$STATE" -v tmp="$TMPSTATE" -v ep="$EPOCH" '
function getstr(s,k,   pat,p,r,q){
  pat="\"" k "\":\""; p=index(s,pat); if(!p)return ""
  r=substr(s,p+length(pat)); q=index(r,"\""); return substr(r,1,q-1)
}
function getnum(s,k,   pat,p,r,i,c,n){
  pat="\"" k "\":"; p=index(s,pat); if(!p)return 0
  r=substr(s,p+length(pat)); n=""
  for(i=1;i<=length(r);i++){ c=substr(r,i,1); if(c~/[0-9]/)n=n c; else break }
  return n+0
}
BEGIN{
  while((getline line < st)>0){
    split(line,a," "); pUp[a[1]]=a[2]; pDn[a[1]]=a[3]
  }
  close(st)
}
{
  s=$0
  p=index(s,"\"connections\":["); if(!p)exit
  s=substr(s,p+15)
  sub(/\][[:space:]]*$/,"",s)          # 去掉数组结尾 ]
  gsub(/[[:space:]]/,"",s)             # 域名/节点名无空格，压缩后便于切分
  m=split(s,rec,/\},\{/)
  for(i=1;i<=m;i++){
    c=rec[i]
    id=getstr(c,"id"); if(id=="")continue
    up=getnum(c,"upload"); dn=getnum(c,"download")
    src=getstr(c,"sourceIP")
    host=getstr(c,"host")
    if(host=="")host=getstr(c,"sniffHost")
    if(host=="")host=getstr(c,"destinationIP")
    rule=getstr(c,"rulePayload")
    proxy=0
    cp=index(c,"\"chains\":[")
    if(cp){
      cs=substr(c,cp+10); e=index(cs,"]"); cs=substr(cs,1,e-1)
      # 字符类里放转义括号在 BusyBox awk 不可靠，分三条去引号/方括号
      gsub(/"/,"",cs); gsub(/\[/,"",cs); gsub(/\]/,"",cs)
      nh=split(cs,el,",")
      for(j=1;j<=nh;j++) if(el[j]!="DIRECT" && el[j]!="REJECT" && el[j]!="") proxy=1
    }
    # 新连接首轮只建基线（其累计值可能已不小），下一轮起算增量
    du=0; dd=0
    if(id in pUp){
      du=up-pUp[id];   if(du<0)du=0
      dd=dn-pDn[id];   if(dd<0)dd=0
    }
    if(du>0||dd>0) print ep","src","host","rule","proxy","dd","du >> csv
    print id" "up" "dn > tmp
  }
}
END{ close(csv); close(tmp) }
'

[ -s "$TMPSTATE" ] && mv -f "$TMPSTATE" "$STATE"
find $DIR -name 'meter-*.csv' -mtime +$KEEP -delete 2>/dev/null
exit 0
