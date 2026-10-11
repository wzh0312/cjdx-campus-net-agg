#!/bin/sh
# ============================================================
#  /etc/drcom/wanx-dhcp.sh      （多线路版 udhcpc 回调）
#  由 wanx_setup.sh 以 TBL= / PREF= / GWA= 环境变量启动 udhcpc 时调用
#
#  设计要点:
#    * 地址按 /32 安装 —— 不产生 /20 主表直连路由，与 wan 零冲突
#    * 路由只写进各自独立表 TBL，主表(main) 全程零改动
#    * 只对「DHCP 实际下发的网关」做 /32 on-link 路由，
#      不依赖掩码、不硬编码任何动态 IP
#    * 源策略 ip rule pref PREF from <本次实际获得的 IP>
#    * DHCP 续约换 IP 时自动重建规则，不残留旧规则
#
#  ============================================================
#  ⚠️ 2026-10-09 修复：cleanup_routes 会误删负载均衡的 fwmark 规则
#  ------------------------------------------------------------
#  原来是：
#      ip rule show | grep "lookup $TBL\$" | while read PRIO _REST; do ... del
#  本意是删「本表的源策略规则」，但 grep 匹配的是【本表的所有规则】。
#  负载均衡层的规则长这样：
#      2001: from all fwmark 0x20000/0xff0000 lookup 100
#  它的 lookup 也正是 100/101/102，于是被一并删掉。
#
#  后果（实测）：每次 DHCP 续约就删掉一条，且没有任何组件会重新加回来，
#  局域网流量于是全部落到主表（A 路），负载均衡【静默失效】。
#  2026-10-09 当天 07:49 / 10:49 / 16:49 三条线先后续约，
#  2003 / 2002 / 2001 依次被删，就是这个原因。
#  （2000 用 lookup main，不匹配，所以侥幸存活 —— 这也解释了为什么只少三条。）
#
#  修法：加 `grep -v fwmark`，只删源策略规则。
#  职责边界：本脚本只管 from <ip> lookup <TBL> 这类源策略规则；
#           fwmark 规则归 /etc/init.d/drcom-lb 管。两者不得互相删。
#  ============================================================

IFACE=$interface
TBL=${TBL:-0}
PREF=${PREF:-0}
GWA=${GWA:-}
TAG=drcom-dhcp

cleanup_routes() {
  if [ "$TBL" != "0" ] && [ "$PREF" != "0" ]; then
    # 只删「本接口的源策略规则」（形如:  pref N  from <ip>  lookup <TBL>）
    # 绝不删 fwmark 规则（形如: pref 2000 from all fwmark 0x... lookup <TBL>）
    # 少了 grep -v fwmark 就会把负载均衡规则一起删掉，见文件头说明。
    ip rule show | grep "lookup $TBL\$" | grep -v fwmark | while read PRIO _REST; do
      P=${PRIO%:}
      ip rule del pref "$P" 2>/dev/null
    done
    ip route flush table "$TBL" 2>/dev/null
  fi
}

case "$1" in
  deconfig)
    ip -4 addr flush dev "$IFACE" 2>/dev/null
    cleanup_routes
    logger -t $TAG "$IFACE deconfig"
    ;;

  bound|renew)
    [ -n "$ip" ] || { logger -t $TAG "$IFACE ERROR no-ip-from-dhcp"; exit 1; }

    ip -4 addr flush dev "$IFACE" 2>/dev/null
    cleanup_routes

    # /32 地址：只在 local 表产生条目，主表不新增 /20 直连路由
    ip -4 addr add "$ip/32" dev "$IFACE"

    if [ "$TBL" != "0" ] && [ "$PREF" != "0" ]; then
      GW=${router:-$GWA}
      if [ -z "$GW" ]; then
        logger -t $TAG "$IFACE ERROR no-gateway"
        exit 1
      fi
      # 网关 /32 on-link，不依赖掩码
      ip route add "$GW/32" dev "$IFACE" scope link src "$ip" table "$TBL"
      # 默认路由
      ip route add default via "$GW" dev "$IFACE" table "$TBL"
      # 源策略
      ip rule add pref "$PREF" from "$ip" lookup "$TBL"
    fi

    logger -t $TAG "$IFACE READY ip=$ip gw=${router:-none} table=$TBL pref=$PREF"
    ;;

  leasefail|nak)
    logger -t $TAG "$IFACE WARN dhcp-$1"
    ;;
esac

exit 0
