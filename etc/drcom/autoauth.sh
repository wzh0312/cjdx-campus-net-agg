#!/bin/sh
# ============================================================
#  示例大学 Dr.COM Portal 自动认证 —— 单账号（生产版 / 方案B）
# ------------------------------------------------------------
#  安装位置 : /etc/drcom/autoauth.sh          (755 root:root)
#  凭据文件 : /etc/drcom/drcom.conf           (600 root:root)
#               第 1 行 = 校园网账号
#               第 2 行 = 预先在电脑本地算好的 upass 凭据
#               ** 文件内不含明文密码 **
#  日志     : logger -t drcom-autoauth  ->  logd / syslog
#              不落地日志文件，不长期占用 /overlay
#  调度     : cron  */2 * * * * /etc/drcom/autoauth.sh
#  依赖     : curl, logger, ip, mkdir —— 全部系统自带，无新增包
# ------------------------------------------------------------
#  本脚本刻意不做的事（安全约束）:
#    * 全脚本不出现 uci set / uci commit      -> 不改任何配置
#    * 全脚本不出现 ifup / ifdown / network restart -> 不重拨 WAN
#    * 不碰 br-lan / 防火墙 / LAN IP / 无线 / 路由表
#    * 日志不含明文密码 / upass / 完整 POST body / 敏感认证参数
#    * 无无界循环（所有循环都有硬上限）
# ------------------------------------------------------------
#  用法:
#    autoauth.sh        正常模式：已在线直接退出，离线才登录
#    autoauth.sh -f     强制登录一次（仅测试用，跳过在线判定与冷却）
# ============================================================

CONF=${DRCOM_CONF:-/etc/drcom/drcom.conf}
LOCK=${DRCOM_LOCK:-/var/lock/drcom.lock}
STATE=${DRCOM_STATE:-/tmp/drcom.lastlogin}

TAG=drcom-autoauth
PORTAL=http://PORTAL_HOST/0.htm
PROBE=http://connect.rom.miui.com/generate_204
PROBE2=http://www.gstatic.com/generate_204
HDRPROBE=http://www.msftconnecttest.com/connecttest.txt

CURL_TO=8          # 单次请求超时（秒）
MAX_ATTEMPTS=2     # 每次运行最多尝试登录次数
COOLDOWN=60        # 两次登录尝试最小间隔（秒）
UPASS_LEN=41       # 合法 upass 长度 = 32(hex md5) + 8(calg) + 1(pid)

FORCE=0
[ "$1" = "-f" ] && FORCE=1

# 唯一出口：syslog，只允许 时间/状态/打码账号/WAN IP
log() { logger -t "$TAG" "$*" 2>/dev/null; }

# 在线判定：任一 204 探测点返回 204 即视为通
probe_online() {
  c=$(curl -s -m "$CURL_TO" -o /dev/null -w '%{http_code}' "$PROBE" 2>/dev/null)
  [ "$c" = "204" ] && return 0
  c=$(curl -s -m "$CURL_TO" -o /dev/null -w '%{http_code}' "$PROBE2" 2>/dev/null)
  [ "$c" = "204" ] && return 0
  return 1
}

# 门户判定：确认是 Dr.COM 劫持，避免把普通断网误判成需要登录
detect_portal() {
  loc=$(curl -s -m "$CURL_TO" -o /dev/null -w '%{redirect_url}' "$HDRPROBE" 2>/dev/null)
  case "$loc" in
    *PORTAL_HOST*) return 0 ;;
  esac
  body=$(curl -s -m "$CURL_TO" "$HDRPROBE" 2>/dev/null | head -c 4096)
  case "$body" in
    *DrcomServer*|*Dr.COMWebLoginID*|*drcom*) return 0 ;;
  esac
  return 1
}

# ============================================================
# 主流程
# ============================================================

# --- 0) 互斥锁，防止 cron 叠加 ---
if ! mkdir "$LOCK" 2>/dev/null; then
  log "WARN skip-locked"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# --- 1) 读凭据（第2行是已算好的 upass，本脚本不做任何密码运算）---
if [ ! -r "$CONF" ]; then
  log "WARN cred-unreadable"
  exit 1
fi
U=$(sed -n 1p "$CONF" | tr -d '\r\n')
H=$(sed -n 2p "$CONF" | tr -d '\r\n')
if [ -z "$U" ] || [ -z "$H" ]; then
  log "WARN cred-empty"
  exit 1
fi
if [ ${#H} -ne "$UPASS_LEN" ]; then
  log "WARN cred-badformat len=${#H} expect=${UPASS_LEN}"
  exit 1
fi
MASK=$(printf '%s' "$U" | cut -c1-2)

# --- 2) WAN 是否有地址（只读检查，无地址则不做任何动作）---
WANIP=$(ip -4 addr show wan 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
if [ -z "$WANIP" ]; then
  log "WARN no-wan-ip user=${MASK}**"
  exit 0
fi

# --- 3) 已在线则直接收工（幂等，不重复认证）---
if [ "$FORCE" != "1" ] && probe_online; then
  log "ONLINE wan=${WANIP}"
  exit 0
fi

# --- 4) 安全阀：必须是 Dr.COM 门户才动手 ---
if [ "$FORCE" != "1" ] && ! detect_portal; then
  log "WARN not-drcom-portal wan=${WANIP}"
  exit 0
fi

# --- 5) 冷却，避免高频轰击认证服务器 ---
NOW=$(date +%s)
LAST=0
[ -f "$STATE" ] && LAST=$(cat "$STATE" 2>/dev/null)
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
if [ "$FORCE" != "1" ] && [ $((NOW - LAST)) -lt "$COOLDOWN" ]; then
  log "WARN cooldown remain=$((COOLDOWN - (NOW - LAST)))s wan=${WANIP}"
  exit 0
fi
echo "$NOW" > "$STATE"

# --- 6) 组装并提交登录（upass 直接来自凭据文件，脚本内无明文密码）---
BODY="DDDDD=${U}&upass=${H}&R1=0&R2=1&para=00&0MKKey=123456&v6ip="

n=1
while [ "$n" -le "$MAX_ATTEMPTS" ]; do
  curl -s -m "$CURL_TO" -o /dev/null -X POST "$PORTAL" --data "$BODY" >/dev/null 2>&1
  sleep 3
  if probe_online; then
    log "LOGIN_SUCCESS attempt=${n} user=${MASK}** wan=${WANIP}"
    exit 0
  fi
  n=$((n + 1))
done

log "LOGIN_FAIL attempts=${MAX_ATTEMPTS} user=${MASK}** wan=${WANIP}"
exit 1
