# 长江大学东校区 · 通过路由器进行网络聚合的一种方法

> 在 BT-R320 / ImmortalWrt 上，把多条校园网线路（多个 Dr.COM 账号的有线口 + 一条以无线 STA
> 方式接入的校园 WiFi）聚合成一个逻辑出口，做基于连接的负载均衡与逐线认证。


在 **ImmortalWrt（MediaTek MT7981 / filogic，`mtwifi` 无线驱动）** 上，把多条校园网线路
——多个 Dr.COM 账号的有线口 + **一条以「无线 STA」方式接入校园 WiFi 的上行**——
聚合成一个逻辑出口，做**基于连接的负载均衡**与**每线路独立的 Dr.COM 门户认证**。

用途：分摊单账号配额、突破单口 100 Mbps 上限。

> ⚠️ 本仓库是**通用化 / 已脱敏**版本，脚本里的校园专有参数都替换成了占位符，部署前请替换（见下）。
> ⚠️ 与 `mwan3` **不兼容**，请勿同时安装。本方案自带一套极简 LB 层。

---

## 目录结构

```
etc/
  drcom/
    lines.conf          # 线路定义表（type=netifd|macvlan|physical|sta）
    autoauth.sh         # 单账号 Dr.COM 门户自动认证（账号 A 用）
    multiauth.sh        # 多线路逐线认证（cron */2）
    wanx_setup.sh       # 幂等：确保各线路接口存在 + 起 udhcpc
    wanx-dhcp.sh        # udhcpc 回调：装地址/路由/源策略
    wifi-line-up.sh     # 幂等：拉起校园 WiFi STA（apcli）并关联
    lb_mark.nft         # LB 标记链（ct mark 分配）
    lb_forward.nft      # LAN -> 各线路 转发放行
    lb_nat.nft          # LAN -> 各线路 显式 SNAT(masquerade)
    ctmark_watch.sh     # ct mark 使用者的只读告警
  init.d/
    drcom-lb            # 开机恢复 ip rule（fwmark -> 表）
    drcom-multi         # 开机拉起各线路 + 跑一轮认证
    drcom-wifi-line     # 开机拉起校园 WiFi STA 线路
  nftables.d/
    99-drcom-lb.nft     # 上文 lb_mark.nft 的部署副本（fw4 自动包含）
examples/
  cred.conf.example     # 线路凭据文件格式（真实凭据不要提交）
```

---

## 工作原理

1. **线路抽象** `lines.conf`：每行一条线路
   `名字 接口 类型 MAC 路由表 规则优先级 凭据文件`
   - `netifd`   —— 由 OpenWrt 自管（现有 wan），脚本只读不动；
   - `macvlan`  —— 在父接口上建 macvlan 逻辑口；
   - `physical` —— 直接用某个真实网口；
   - `sta`      —— **无线 STA**（如 `apclix0`，关联由 `wifi-line-up.sh` 建立）。

2. **每线独立 DHCP**：`wanx_setup.sh` 为每条线拉起 `udhcpc`（回调 `wanx-dhcp.sh`），
   把地址按 **/32** 装、默认路由与网关 /32 只写进该线**独立路由表**，并加一条
   **源策略** `ip rule pref <PREF> from <该线IP> lookup <表>`。主表（main）全程不改。

3. **负载均衡标记** `lb_mark.nft`（hook `prerouting priority mangle + 5`）：
   `iifname br-lan ct state new` 的新连接，用 `jhash(saddr.daddr.proto.sport.dport) mod N`
   一次性映射成 `ct mark`（`0x00010000`、`0x00020000`… 每线一个值），再**仅对 br-lan 入向**
   还原到 `meta mark`。
   > ⚠️ 必须用「**单规则 + map**」写法；拆成「每线一条比较 jhash 取值」的写法在高并发下
   > 会大面积漏标（实测漏标 28%~46%），导致流量全挤到一条线。

4. **选路**：`ip rule pref 2000..200N` 按 `fwmark/0x00FF0000` 选择对应的路由表。

5. **逐线认证** `multiauth.sh`（cron `*/2`）：对每条线独立走
   `DHCP_READY -> ROUTE_READY -> PORTAL_CHECK -> LOGIN -> VERIFY_204`，
   所有探测都 `--interface <该线IP>` 显式绑定源地址。任一路失败不影响其他线。

6. **校园 WiFi 作为一条线**：`mtwifi` 驱动的 `apcli` 接口（`apcli0`/`apclix0`）即 STA。
   `wifi-line-up.sh` 幂等地把它关联到校园 SSID。
   > ⚠️ 同一射频上 **AP 与 STA 必须同信道**，所以要先把本地 AP 的信道对齐到校园 AP 的信道；
   > 代价是本地该频段会与 STA 共享空口（带宽下降）。

---

## 部署

1. 把 `etc/drcom/*`、`etc/init.d/drcom-*` 放到路由器的 `/etc/...`，`99-drcom-lb.nft` 放到
   `/etc/nftables.d/`；`chmod +x` 各脚本与 init。
2. 建凭据文件 `/etc/drcom/cred-*.conf`（`chmod 600`），格式见 `examples/cred.conf.example`。
3. 按下方表格替换所有占位符。
4. 在 `/etc/config/firewall` 里加两条 include（指向 `lb_forward.nft` / `lb_nat.nft`），
   然后 `fw4 reload`。
5. `crontab`：`*/2 * * * * /etc/drcom/multiauth.sh` 与 `*/2 * * * * /etc/drcom/wifi-line-up.sh`。
6. `/etc/init.d/drcom-wifi-line enable && /etc/init.d/drcom-multi enable && /etc/init.d/drcom-lb enable`。

### 需要替换的占位符

| 占位符 | 含义 |
|---|---|
| `PORTAL_HOST` | 校园 Dr.COM 门户服务器地址 |
| `WIRED_GATEWAY` | 有线线路的默认网关（仅作 DHCP 未下发网关时的回退） |
| `CAMPUS_SSID` / `CAMPUS_SSID_5G` | 校园无线 SSID |
| `CAMPUS_AP_BSSID` | 目标校园 AP 的 BSSID（可选，留空则按 SSID 关联） |
| `02:00:00:00:00:0A` … `0D` | 各线路的独立 MAC（示例值，请自行分配本地管理 MAC） |
| `cred-a.conf` … `cred-d.conf` | 各线路的凭据文件名（内容不要提交） |

---

## 注意事项 / 踩过的坑

- **mwan3 不兼容**，别装。
- **硬件加速（HNAT / flow offload）需关闭**，否则本方案的 nft 计数与标记会被旁路。
- **OpenClash / 透明代理开启时**，LAN 流量会被 TPROXY 截到路由器本地，其出站是「本机流量」，
  不参与本 LB —— 结果就是 LB 对 LAN 客户端**静默失效**。二者需另做处理（如按 skuid 标记代理出站）。
- **`ip rule` 清理 bug**：用 `ip rule show | grep "lookup <表>"` 找自己的源策略规则时，
  LB 的 fwmark 规则也会命中，DHCP 续约会把 LB 规则误删。务必 `grep -v fwmark`。
- **Dr.COM `upass` 是明文等价凭据**：`upass = md5("2" + password + "12345678") + "12345678" + "2"`
  （*该盐值为特定厂商/门户实现，其他校园可能不同*）。日志里绝不要打印账号/upass。

---

## 安全

- 本仓库**不含任何真实凭据**；真实凭据放 `/etc/drcom/cred-*.conf`（`chmod 600`），且不要提交。
- `.gitignore` 已排除 `cred-*.conf` / `drcom.conf` 等。

## 许可

MIT（见 `LICENSE`）。
