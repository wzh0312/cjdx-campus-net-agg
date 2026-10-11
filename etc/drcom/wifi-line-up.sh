#!/bin/sh
# /etc/drcom/wifi-line-up.sh
# 确保校园 5G STA（apclix0）在线。幂等：已连上目标 SSID 则直接退出，不做任何改动。
# 由两个入口调用：/etc/init.d/drcom-wifi-line（开机）、cron */2（自愈）。
# 与本地 AP(rax0) 同射频，故需先把 rax0 信道对齐到校园 AP 所在信道（仅在不同时才动）。
TAG=drcom-wifi-line
SSID="CAMPUS_SSID_5G"
BSSID=CAMPUS_AP_BSSID
CH=44

# 已经连在目标 SSID 上 -> 无操作（避免每轮都动信道打扰本地 AP）
if iwinfo apclix0 info 2>/dev/null | grep -q "ESSID: \"$SSID\""; then
  exit 0
fi

# 等 5G 射频就绪（最多 20s）
ok=0; n=0
while [ $n -lt 20 ]; do
  iwinfo rax0 info >/dev/null 2>&1 && { ok=1; break; }
  sleep 1; n=$((n+1))
done
[ "$ok" = "1" ] || { logger -t $TAG "rax0 not ready, give up"; exit 1; }

# AP 信道对齐（只在不同时才切，避免无谓扰动本地 5G 客户端）
cur=$(iwinfo rax0 info 2>/dev/null | grep -o "Channel: [0-9]*" | head -1 | grep -o "[0-9]*")
if [ "$cur" != "$CH" ]; then
  logger -t $TAG "move rax0 $cur -> $CH"
  iwpriv rax0 set Channel=$CH 2>/dev/null
  sleep 3
fi

# 拉起 STA 接口（mtwifi 要求接口 up 才接受私有 ioctl）
ip link set apclix0 up 2>/dev/null
sleep 1

# 配置 apcli（开放网络）
iwpriv apclix0 set ApCliEnable=0 2>/dev/null
iwpriv apclix0 set ApCliAuthMode=OPEN 2>/dev/null
iwpriv apclix0 set ApCliEncrypType=NONE 2>/dev/null
iwpriv apclix0 set "ApCliSsid=$SSID" 2>/dev/null
iwpriv apclix0 set ApCliBssid=$BSSID 2>/dev/null
iwpriv apclix0 set ApCliEnable=1 2>/dev/null
sleep 5

if iwinfo apclix0 info 2>/dev/null | grep -q "ESSID: \"$SSID\""; then
  logger -t $TAG "apcli connected"
  exit 0
fi
logger -t $TAG "apcli connect failed"
exit 1
