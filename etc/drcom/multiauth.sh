#!/bin/sh
# ============================================================
#  /etc/drcom/multiauth.sh
#  多线路独立健康检查 + Portal 自动认证
#
#  每一路独立走完整流程:
#     DHCP_READY -> ROUTE_READY -> PORTAL_CHECK -> LOGIN -> VERIFY_204
#  任一路失败只记录该路，绝不影响其他线路
#
#  保留的安全机制:
#     互斥锁 / 超时 / 有限重试 / 冷却 / Portal 识别安全阀 / 日志脱敏
#
#  所有探测均 --interface 显式绑定源地址，绝不靠默认路由判断他路
# ============================================================

CONF=/etc/drcom/lines.conf
LOCK=/var/lock/drcom-multi.lock
SDIR=/tmp/drcom-multi
TAG=drcom-multi

PORTAL=http://PORTAL_HOST/0.htm
PROBE=http://connect.rom.miui.com/generate_204
PROBE2=http://www.gstatic.com/generate_204
HDRPROBE=http://www.msftconnecttest.com/connecttest.txt

CURL_TO=8
LOGIN_TO=40
MAX_ATTEMPTS=2
COOLDOWN=60

mkdir -p "$SDIR" 2>/dev/null
log() { logger -t $TAG "$*" 2>/dev/null; }

# ---------- 探测（全部显式绑定源地址）----------
probe_online() {
  c=$(curl -s -m $CURL_TO --interface "$1" -o /dev/null -w '%{http_code}' "$PROBE"  2>/dev/null)
  [ "$c" = "204" ] && return 0
  c=$(curl -s -m $CURL_TO --interface "$1" -o /dev/null -w '%{http_code}' "$PROBE2" 2>/dev/null)
  [ "$c" = "204" ] && return 0
  return 1
}

detect_portal() {
  loc=$(curl -s -m $CURL_TO --interface "$1" -o /dev/null -w '%{redirect_url}' "$HDRPROBE" 2>/dev/null)
  case "$loc" in *PORTAL_HOST*) return 0 ;; esac
  body=$(curl -s -m $CURL_TO --interface "$1" "$HDRPROBE" 2>/dev/null | head -c 4096)
  case "$body" in *DrcomServer*|*Dr.COMWebLoginID*|*drcom*) return 0 ;; esac
  return 1
}

# ---------- 单线路 ----------
handle_line() {
  NAME=$1; IF=$2; TBL=$3; PREF=$4; CRED=$5
  ST=$SDIR/$NAME.state
  LASTF=$SDIR/$NAME.last

  # ===== 1) DHCP_READY =====
  IP=$(ip -4 addr show "$IF" 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
  if [ -z "$IP" ]; then
    prev=$(cat "$ST" 2>/dev/null)
    [ "$prev" != "NOIP" ] && log "$NAME DHCP_NOT_READY if=$IF"
    echo "NOIP" > "$ST"
    return 1
  fi

  # ===== 2) ROUTE_READY（仅 table>0 的线路需要）=====
  if [ "$TBL" != "0" ]; then
    if ! ip rule show | grep -q "from $IP lookup $TBL"; then
      prev=$(cat "$ST" 2>/dev/null)
      [ "$prev" != "NOROUTE" ] && log "$NAME ROUTE_NOT_READY ip=$IP table=$TBL"
      echo "NOROUTE" > "$ST"
      return 1
    fi
  fi

  # ===== 3) PORTAL_CHECK / VERIFY_204 =====
  if probe_online "$IP"; then
    prev=$(cat "$ST" 2>/dev/null)
    [ "$prev" != "ONLINE" ] && log "$NAME ONLINE ip=$IP"
    echo "ONLINE" > "$ST"
    return 0
  fi

  # ===== 4) 安全阀：确认是 Dr.COM 门户才动手 =====
  if ! detect_portal "$IP"; then
    prev=$(cat "$ST" 2>/dev/null)
    [ "$prev" != "NOPORTAL" ] && log "$NAME WARN not-drcom-portal ip=$IP"
    echo "NOPORTAL" > "$ST"
    return 1
  fi

  # ===== 5) 冷却 =====
  NOW=$(date +%s)
  LAST=0
  [ -f "$LASTF" ] && LAST=$(cat "$LASTF" 2>/dev/null)
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  if [ $((NOW - LAST)) -lt $COOLDOWN ]; then
    log "$NAME WARN cooldown remain=$((COOLDOWN - (NOW - LAST)))s ip=$IP"
    return 1
  fi
  echo "$NOW" > "$LASTF"

  # ===== 6) 读凭据（第2行是已算好的 upass，本脚本不做密码运算）=====
  if [ ! -r "$CRED" ]; then
    log "$NAME WARN cred-unreadable"
    echo "NOCRED" > "$ST"
    return 1
  fi
  U=$(sed -n 1p "$CRED" | tr -d '\r\n')
  H=$(sed -n 2p "$CRED" | tr -d '\r\n')
  if [ -z "$U" ] || [ -z "$H" ]; then
    log "$NAME WARN cred-empty"
    echo "NOCRED" > "$ST"
    return 1
  fi
  if [ ${#H} -ne 41 ]; then
    log "$NAME WARN cred-badformat"
    echo "NOCRED" > "$ST"
    return 1
  fi
  MASK=$(printf '%s' "$U" | cut -c1-2)

  # ===== 7) LOGIN（GET 存 cookie -> 带浏览器头 POST，源绑定）=====
  CK=$SDIR/ck-$NAME.txt
  rm -f "$CK"
  curl -s -m $CURL_TO --interface "$IP" -c "$CK" -o /dev/null "$PORTAL" 2>/dev/null

  BODY="DDDDD=${U}&upass=${H}&R1=0&R2=1&para=00&0MKKey=123456&v6ip="
  unset H

  n=1
  while [ "$n" -le "$MAX_ATTEMPTS" ]; do
    # --data @- 从 stdin 读 body：upass 不进 curl 的 argv，ps 看不到
    printf '%s' "$BODY" | curl -s -m $LOGIN_TO --interface "$IP" -b "$CK" -o /dev/null \
         -H 'Content-Type: application/x-www-form-urlencoded' \
         -H "Referer: $PORTAL" \
         -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' \
         -X POST "$PORTAL" --data @- >/dev/null 2>&1
    sleep 3
    if probe_online "$IP"; then
      rm -f "$CK"
      unset BODY
      log "$NAME LOGIN_SUCCESS attempt=$n user=${MASK}** ip=$IP"
      echo "ONLINE" > "$ST"
      return 0
    fi
    n=$((n + 1))
  done

  unset BODY
  rm -f "$CK"
  log "$NAME LOGIN_FAIL attempts=$MAX_ATTEMPTS user=${MASK}** ip=$IP"
  echo "OFFLINE" > "$ST"
  return 1
}

# ============ 主流程 ============
if ! mkdir "$LOCK" 2>/dev/null; then
  logger -t $TAG "WARN skip-locked"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# 幂等确保 macvlan 线路与 DHCP 进程存在
[ -x /etc/drcom/wanx_setup.sh ] && /etc/drcom/wanx_setup.sh

grep -v '^#' "$CONF" | grep -v '^[[:space:]]*$' | \
while read NAME IF TYPE MAC TBL PREF CRED; do
  [ -n "$NAME" ] && handle_line "$NAME" "$IF" "$TBL" "$PREF" "/etc/drcom/$CRED"
done

exit 0
