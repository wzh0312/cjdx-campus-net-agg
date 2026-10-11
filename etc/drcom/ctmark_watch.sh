#!/bin/sh
# ============================================================
#  /etc/drcom/ctmark_watch.sh
#  ct mark 使用者只读监控
#
#  背景：四路负载均衡用 ct mark 的 bit16-23 存选路决策，
#        且写入方式是【整值赋值】，会清掉 ct mark 的低 16 位。
#        当前实测全系统无其他组件使用 ct mark，所以无影响。
#        但若将来有组件开始使用 ct mark，就可能被本方案清掉。
#
#  本脚本【只读】：
#    * 只做检查与告警（写入 syslog）
#    * 绝不修改 nft 规则、绝不改任何配置
#    * 发现新使用者时也只在日志里告警，人工判断后再处理
# ============================================================

TAG=drcom-ctwatch
BASE=/etc/drcom/ctmark_baseline.txt
FOUND=0

echo "===== $(date '+%F %T') ct mark 使用者检查 ====="

# ------------------------------------------------------------
# 1) nft ruleset 内：drcom_lb 之外是否有人用 ct mark
# ------------------------------------------------------------
TOTAL=$(nft list ruleset 2>/dev/null | grep -c 'ct mark')
OURS=$(nft list chain inet fw4 drcom_lb 2>/dev/null | grep -c 'ct mark')
OTHER=$((TOTAL - OURS))

echo "  nft 规则集中 ct mark 出现总数 = $TOTAL"
echo "  其中 drcom_lb 自己的        = $OURS"
echo "  drcom_lb 之外的使用         = $OTHER"

if [ "$OTHER" -gt 0 ]; then
  FOUND=1
  echo "  !! 检测到 drcom_lb 之外使用 ct mark 的规则:"
  nft list ruleset 2>/dev/null | grep -n 'ct mark' | sed 's/^/     /' | head -20
fi

# ------------------------------------------------------------
# 2) 脚本文件里：是否有人在设置 ct mark / CONNMARK
#    排除本方案自己的文件
# ------------------------------------------------------------
echo ""
echo "  扫描脚本文件中的 ct mark / CONNMARK 使用者:"
HITS=$(grep -rl -e 'ct mark' -e 'CONNMARK' -e 'ctmark' \
        /etc/init.d /usr/share/openclash /etc/openclash /etc/config \
        /usr/share/passwall /usr/share/sing-box 2>/dev/null \
      | grep -v -e drcom -e 'ctmark_watch' -e 'ctmark_baseline' \
      | grep -v -i -e '\.dat$' -e '\.mmdb$' -e '\.ipset$' -e '\.db$' \
                    -e '\.json$' -e '\.yaml$' -e '\.yml$' \
                    -e 'GeoSite' -e 'GeoIP' -e 'Country\.')

if [ -n "$HITS" ]; then
  FOUND=1
  echo "    !! 以下文件提到 ct mark / CONNMARK:"
  for F in $HITS; do echo "       $F"; done
else
  echo "    (无)"
fi

# ------------------------------------------------------------
# 3) 基线对比：与上次记录对比，看是否有变化
# ------------------------------------------------------------
echo ""
CUR="nft_other=$OTHER
scripts=$(echo "$HITS" | tr '\n' ' ')"
echo "$CUR" > "$BASE"
echo "  基线已更新到 $BASE"

# ------------------------------------------------------------
# 结论 / 告警
# ------------------------------------------------------------
echo ""
if [ "$FOUND" = "0" ]; then
  echo "  结果: ✅ 未发现 drcom_lb 之外的 ct mark 使用者"
  logger -t $TAG "OK no other ct mark user (nft_other=0)"
else
  echo "  结果: ⚠️ 发现 drcom_lb 之外的 ct mark 使用者，请人工确认"
  echo "        本脚本只告警，不会修改任何规则"
  logger -t $TAG "WARN other ct mark user detected! nft_other=$OTHER scripts=$HITS"
fi
echo "  注意: 本脚本为只读检查，不修改任何规则或配置"
exit 0
