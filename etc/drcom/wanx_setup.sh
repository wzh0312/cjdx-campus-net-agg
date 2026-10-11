#!/bin/sh
# ============================================================
#  /etc/drcom/wanx_setup.sh
#  确保所有线路存在且已启动 DHCP —— 幂等，可反复执行
#
#  按 lines.conf 的 type 字段分派:
#    netifd   : OpenWrt 自管（账号A）—— 本脚本完全不动
#    macvlan  : 在 $PARENT(wan) 上创建 macvlan 子接口
#    physical : 使用真实物理口（如 lan2）—— 不创建任何虚拟接口
#    sta      : 无线 STA 线路（如 apclix0）—— 关联由 drcom-wifi-line 建立
#
#  ============================================================
#  2026-10-09 变更: 增加 type=physical，用于把 D 线路搬到第二条
#  物理上行 lan2。physical 类型只做三件事：
#     1) 确认设备存在（不存在就报错退出该线路，不静默）
#     2) 设置独立 MAC（MAC 写 '-' 则不动）
#     3) 拉起 udhcpc（回调仍是 wanx-dhcp.sh，路由/源策略逻辑完全一致）
#  其余（netifd / macvlan）行为与旧版一致，未改动。
#  ============================================================

CONF=/etc/drcom/lines.conf
TAG=drcom-setup
GWA=WIRED_GATEWAY
PARENT=wan

[ -r "$CONF" ] || { logger -t $TAG "ERROR lines.conf unreadable"; exit 1; }

start_udhcpc() {
  NAME=$1; IF=$2; TBL=$3; PREF=$4
  PIDF=/var/run/udhcpc-$IF.pid
  ALIVE=0
  if [ -f "$PIDF" ]; then
    P=$(cat "$PIDF" 2>/dev/null)
    case "$P" in ''|*[!0-9]*) ALIVE=0 ;; *) kill -0 "$P" 2>/dev/null && ALIVE=1 ;; esac
  fi
  if [ "$ALIVE" = "0" ]; then
    rm -f "$PIDF"
    TBL="$TBL" PREF="$PREF" GWA="$GWA" \
      nohup udhcpc -i "$IF" -s /etc/drcom/wanx-dhcp.sh \
            -p "$PIDF" -f -t 8 -T 3 >/dev/null 2>&1 &
    logger -t $TAG "$NAME udhcpc-started if=$IF table=$TBL pref=$PREF"
  fi
}

ensure_line() {
  NAME=$1; IF=$2; TYPE=$3; MAC=$4; TBL=$5; PREF=$6

  case "$TYPE" in
    netifd)
      # 由 OpenWrt 管理，本脚本只读不改
      return 0
      ;;

    macvlan)
      if ! ip link show "$IF" >/dev/null 2>&1; then
        if ip link add link "$PARENT" name "$IF" type macvlan mode bridge 2>/dev/null; then
          logger -t $TAG "$NAME created if=$IF type=macvlan parent=$PARENT"
        else
          logger -t $TAG "$NAME ERROR create-failed if=$IF"
          return 1
        fi
      fi
      if [ "$MAC" != "-" ] && [ -n "$MAC" ]; then
        CUR=$(cat /sys/class/net/$IF/address 2>/dev/null)
        if [ "$CUR" != "$MAC" ]; then
          ip link set "$IF" address "$MAC" 2>/dev/null \
            && logger -t $TAG "$NAME mac-set $MAC if=$IF"
        fi
      fi
      ;;

    physical)
      if ! ip link show "$IF" >/dev/null 2>&1; then
        logger -t $TAG "$NAME ERROR physical-if-missing if=$IF"
        return 1
      fi
      if [ "$MAC" != "-" ] && [ -n "$MAC" ]; then
        CUR=$(cat /sys/class/net/$IF/address 2>/dev/null)
        if [ "$CUR" != "$MAC" ]; then
          # 真实物理口改 MAC 需要先 down，否则部分驱动（mt7530 DSA）会拒绝
          ip link set "$IF" down 2>/dev/null
          if ip link set "$IF" address "$MAC" 2>/dev/null; then
            logger -t $TAG "$NAME mac-set $MAC if=$IF type=physical"
          else
            logger -t $TAG "$NAME ERROR mac-set-failed $MAC if=$IF"
          fi
        fi
      fi
      # 物理口默认不做 IPv6 自动配置，避免在校园网侧冒 ND
      sysctl -w net.ipv6.conf.$IF.disable_ipv6=1 >/dev/null 2>&1
      ;;

    sta)
      # 无线 STA 线路（校园 WiFi）。关联由 /etc/init.d/drcom-wifi-line 建立；
      # 本类型只确认接口存在，不动 MAC（STA 用自己的 MAC），关 IPv6 避免冒 ND。
      if ! ip link show "$IF" >/dev/null 2>&1; then
        logger -t $TAG "$NAME ERROR sta-if-missing if=$IF"
        return 1
      fi
      sysctl -w net.ipv6.conf.$IF.disable_ipv6=1 >/dev/null 2>&1
      ;;

    *)
      logger -t $TAG "$NAME ERROR unknown-type=$TYPE if=$IF"
      return 1
      ;;
  esac

  ip link set "$IF" up 2>/dev/null
  start_udhcpc "$NAME" "$IF" "$TBL" "$PREF"
  return 0
}

grep -v '^#' "$CONF" | grep -v '^[[:space:]]*$' | \
while read NAME IF TYPE MAC TBL PREF CRED; do
  ensure_line "$NAME" "$IF" "$TYPE" "$MAC" "$TBL" "$PREF"
done

exit 0
