部署手册

目标是让一台Linux VPS与一台兼容OpenWrt路由器实现：国内外TCP/UDP互联网流量统一经VPS出口、DNS经隧道、阻断 IPv6、隧道失效时不回落直连，并保留服务器SSH 22端口。

本文件是操作手册；工具包根目录的 `scripts/` 与 `templates/` 是可复制的配套文件。单独下载本 Markdown 时，完整源码在第 17 节；建议使用ZIP中已整理好的目录，避免手工保存文件出错。

## 目录

1. 能实现什么，以及适用范围
2. 拓扑与工作原理
3. 依赖清单与架构选择
4. 参数表与部署前检查
5. VPS 安装与准备
6. 生成两端配置
7. 启动服务器、配置防火墙
8. 把路由器文件安全传过去
9. 切换前的 SOCKS 连通性测试
10. 路由器全局接管与自动回滚
11. 逐项验收与断线测试
12. Mac / iPhone 的使用要求
13. 日常管理、更新与重启
14. 回滚与恢复
15. 常见问题与排查顺序
16. 原部署结果、模板差异与验证边界
17. 完整配置附录与参考资料

## 1. 能实现什么，以及适用范围

### 1.1 本方案的能力

| 目标 | 实现方式 | 验收依据 |
|---|---|---|
| 国内外统一出口 | 路由器 TUN 接管 IPv4，无中国大陆直连规则 | 国内探针、外网 IP、目标网站 trace 一致 |
| 加密与流量外观 | VLESS + REALITY + XTLS Vision，TCP 443 | 两端完成真实握手，业务请求成功 |
| DNS 不经国内运营商 | dnsmasq → 本机 Xray → 隧道 → 1.1.1.1 | DNS 泄漏检测与 WAN 阻断规则 |
| WebRTC 不暴露另一公网地址 | UDP/STUN 同样通过隧道 | 浏览器检测 + 两个独立 STUN 服务器 |
| 禁用 IPv6 | 网络分配、内核、防火墙三层处理 | 无 IPv6 外网路由，显式 IPv6 请求失败 |
| 隧道失效不直连 | 与 Xray 进程独立的 nftables 规则 | 停止服务后 HTTPS、DNS 均不能绕过 |
| 精简 VPS 入站端口 | UFW 默认拒绝，仅放行必要端口 | 规则审计、SSH 重新连接 |

REALITY 是 TLS 外观伪装与认证机制，不保证永不被识别或封锁。固定 VPS 出口也不等于住宅 IP，商业数据库仍可能标记机房、VPN 或代理。WebRTC 测试通过只说明这次测试未发现第二个公网出口，不能保证设备上的其他网络接口、其他 VPN 或蜂窝网络永远不会产生另外的出口。

这里的“全局”指通过这台路由器的常规 TCP/UDP 互联网连接。局域网通信、ARP、DHCP 等维持本地网络的流量不会送到美国；不承诺承载所有原始 IP 协议，也不要把 ICMP ping 当成唯一验收方法。

系统语言、时区、浏览器区域、账号资料和机房属性无需理会。

### 1.2 自动应用脚本的明确范围

配套的 `apply-router.sh` 只用于**新部署**，要求：

- VPS：使用 systemd 的 Debian/Ubuntu，示例以 Debian 12 / Ubuntu 22.04、24.04 的命令习惯编写；原实例使用 Ubuntu 20.04，但其他发行版没有在本次项目中实机验收。
- 路由器：OpenWrt / 兼容发行版，已有 firewall4（fw4）+ nftables、UCI、procd、dnsmasq。
- 拓扑：一条 DHCP IPv4 WAN，一个静态 LAN 网段；路由器真正作为网关，而非单纯 AP 或旁路由。
- LAN、WAN 使用不同的 Linux 网络设备；可以从 LAN 管理路由器。
- 没有正在生效的其他 VPN、策略路由、多 WAN 或代理插件。
- 现有 `/etc/init.d/us-vpn`、`/etc/us-vpn` 等路径不存在，避免覆盖旧安装。

**PPPoE、双 WAN、多个 VLAN/访客网、旁路由、桥接 AP、fw3/iptables、企业防火墙、Docker 混合网关不属于脚本的直接适用范围。**这些情况可以借鉴原理，但要重新设计接口匹配、区域转发与例外规则。不要为了让脚本通过而删除它的检查。

内核模块必须与正在运行的 OpenWrt 固件完全匹配。遇到 kmod 版本/校验不匹配，不要强制安装。

## 2. 拓扑与工作原理

```text
Mac / iPhone / 其他 LAN 设备
       │  默认网关 = OpenWrt 的 LAN IP
       ▼
OpenWrt LAN（例如 br-lan，10.0.0.1/24）
       │  全部常规 IPv4 TCP/UDP
       ▼
Xray TUN：us-tun，172.31.255.1/30，MTU 1400
       │  VLESS + REALITY + Vision
       │  经真实 WAN 接口绑定，连接 VPS_IP:443/TCP
       ▼
老外 VPS / Xray 服务
       │  IPv4 出站
       ▼
国内网站、国外网站、STUN 服务器、公共 DNS
```

DNS 单独进入本机监听端口：

```text
设备 UDP/TCP 53 → 路由器 dnsmasq:53
              → 127.0.0.1:5353（Xray tunnel 入站）
              → 同一条 REALITY 隧道
              → VPS → 1.1.1.1:53
```

DNS 在路由器至 VPS 这一段受隧道加密保护；VPS 到 1.1.1.1 使用普通 DNS，本方案没有额外部署 DoH 服务器。设备自行使用 DoH/DoT 时，其连接仍走全局隧道，但检测页可能显示设备选择的其他解析服务。

两条 `0.0.0.0/1` 与 `128.0.0.0/1` 路由覆盖全部 IPv4 空间；局域网更具体的路由仍优先。Xray 的加密连接绑定 WAN 真实设备，避免被送回 TUN。不能把路由器自己的默认路由改成 VPS 公网地址：VPS 不是本地链路的下一跳。

## 3. 依赖清单与架构选择

### 3.1 三个执行位置

全文代码块之前标明执行位置：

- **管理电脑**：有 SSH/SCP 的 Mac、Linux 或 Windows OpenSSH，用于连接两台设备和中转文件。
- **VPS**：使用 root 或先 `sudo -i`；需要联网下载官方发布包。
- **路由器**：通过 LAN SSH 登录 root；这里执行的防火墙命令会影响全网连接。

不要把路由器脚本粘贴进管理电脑终端直接运行。不要从 VPS 直接访问 `10.0.0.1` 来传文件；那是你的家庭私网地址，VPS 通常无法访问。

### 3.2 软件依赖

| 位置 | 必需项 | 用途 |
|---|---|---|
| 管理电脑 | SSH、SCP；可选 Python 3、dig、curl | 登录、中转、独立验证 |
| VPS | curl、ca-certificates、python3、openssl、systemd、ufw | 下载校验、生成配置、TLS 检查、服务和防火墙 |
| VPS | 匹配 CPU 的 Xray 26.10.29 | 服务端 |
| 路由器 | firewall4、nftables、UCI、ubus、jsonfilter、procd、dnsmasq | 防火墙、网络和服务管理 |
| 路由器 | kmod-tun，存在 `/dev/net/tun` | TUN 支持 |
| 路由器 | curl、ca-bundle、ip 命令；建议 ip-full | 连通性验证及路由诊断 |
| 路由器 | 与 CPU/浮点 ABI 匹配的 Xray 26.10.29 | 客户端 |

Python 脚本只使用标准库，不需要 pip。路由器不需要安装 Python、Go 编译器、Docker、sing-box 或 Web 管理面板。内存和空间以实际固件为准；机器应先确认二进制、配置和运行内存有余量。

### 3.3 官方安装包对应关系

| 硬件/ABI | 官方 ZIP | ZIP 内应提取 |
|---|---|---|
| Linux x86_64 / amd64 | `Xray-linux-64.zip` | `xray` |
| Linux ARM64 / aarch64 | `Xray-linux-arm64-v8a.zip` | `xray` |
| MT7621、mipsel_24kc、MIPS little-endian 无硬浮点 | `Xray-linux-mips32le.zip` | **`xray_softfloat`** |
| MIPS 32 位 big-endian 无硬浮点 | `Xray-linux-mips32.zip` | `xray_softfloat`，需确认设备 ABI |
| ARM 32 位 | `Xray-linux-arm32-v5/v6/v7a.zip` | `xray`，必须对应 CPU 能力 |

`uname -m` 在某些 MT7621 固件上只输出 `mips`，无法单独判断大小端。同时读取 `/etc/openwrt_release` 的 `DISTRIB_ARCH`、`DISTRIB_TARGET` 和 `ubus call system board`。

本次实际踩过的坑：MT7621 使用 ZIP 中普通的 `xray` 会报 **Illegal instruction**，而同一个 ZIP 中的 `xray_softfloat` 可正常运行。下载脚本提取后统一命名为 `xray`，复制到路由器后再命名为 `xray-us-vpn`。

本手册固定版本是为了复现已验证的组合，不表示它永久是最新或最佳版本。以后升级必须重新核对配置字段、TLS 指纹和 REALITY 兼容性，不能只更新一端后假设另一端必然兼容。

## 4. 参数表与部署前检查

### 4.1 先写下自己的参数

| 参数 | 含义 | 文档示例/默认值 |
|---|---|---|
| VPS_IP | 新 VPS 的真实公网 IPv4 | 文中 `203.0.113.10` 仅为不可用示例，必须替换 |
| ROUTER_IP | 路由器 LAN 管理地址 | `10.0.0.1`；其他机器可能为 `192.168.1.1` |
| SNI | 经过 VPS 验证的 REALITY 目标域名 | `www.asus.com`，不是永久保证可用 |
| WAN_IF | UCI 逻辑 WAN 接口 | `wan` |
| WAN_DEV | 内核实际 L3 上网设备 | 原机器为 `wan`，其他机器可能是 `eth1`、`eth0.2` |
| LAN_IF | UCI LAN 接口；本脚本要求 DHCP 段同名 | `lan` |
| LAN_DEV | LAN 网桥/设备 | `br-lan` |
| WAN6_IF | UCI IPv6 WAN 接口 | `wan6`，不存在也可以 |
| LAN_ZONE / WAN_ZONE | 防火墙区域的 name | `lan` / `wan`，不是数组下标 |
| TUN_CIDR | 不与任何现有网络重叠的私有 /30 | `172.31.255.1/30` |

**WAN_IF 和 WAN_DEV 不一定相同。**比如逻辑接口叫 `wan`，实际网卡可能叫 `eth1`。Xray 的接口绑定和 nftables 的 `oifname` 要填写 WAN_DEV。

### 4.2 路由器检查：先只读，不修改

在**路由器**运行：

```sh
cat /etc/openwrt_release
ubus call system board
uname -m
df -h
free
ip -4 addr
ip -4 route
ip -6 route
ubus call network.interface.wan status
ubus call network.interface.lan status
uci show network
uci show firewall
uci show dhcp
command -v fw4 nft uci ubus jsonfilter ip curl nohup
ls -l /dev/net/tun
dnsmasq --help | grep -i 'filter-AAAA'
ps w
```

确认：

1. LAN 与上级网络不重叠，例如 LAN `10.0.0.0/24`、WAN `192.168.1.0/24`。
2. `wan` 的协议为 DHCP；只有一条 IPv4 默认路由。
3. 记录 `l3_device`：这是后面使用的 WAN_DEV 和 LAN_DEV。
4. 路由器确实是客户端默认网关。客户端接在另一台 Wi-Fi/AP 上时，可能根本不经过它。
5. `/dev/net/tun` 存在，且 dnsmasq 支持 AAAA 过滤。
6. 没有其他代理进程接管路由；需要停用的旧插件，应先记录其启用状态和配置。
7. TUN 网段没有与现有 LAN、WAN、容器、虚拟机、远程网络重叠。
8. 使用 LAN 管理 SSH，最好有网线或本地恢复方式，不能从将被封锁的 WAN 管理入口操作。

缺少普通依赖时，在**路由器**选择与固件相符的一组命令：

```sh
# 使用 opkg 的固件：
opkg update
opkg install kmod-tun ca-bundle curl ip-full
```

```sh
# 原生使用 apk 的固件：
apk update
apk add kmod-tun ca-bundle curl ip-full
```

不要仅根据版本字符串猜包管理器；某些定制固件有兼容包装命令。fw4/nftables 应已经随目标固件安装，若当前是 fw3，本手册不指导直接替换防火墙体系。

如果是 PassWall 等旧方案，先从它的管理页面停用，并记录原状态；确认其进程、TUN、策略路由已经退出。脚本备份的是执行当时的状态，不会自动恢复你在此前手动停用的旧插件。

### 4.3 VPS 检查

在**VPS**运行：

```sh
sudo -i
uname -m
cat /etc/os-release
ss -lntup
ip -4 route
systemctl --version | head -1
ufw status verbose
```

先确认 TCP 443 没被网站、面板、另一套代理占用。如果已有业务，要先规划其必要端口和迁移方式；不能直接套用“仅留 22/443”的新机器规则。Docker 或云安全组也可能独立改变端口暴露情况，需分别审计。

供应商控制台/安全组至少放行入站 TCP 22、443，允许需要的出站访问。不需要为了本方案把所有 UDP 入站端口放开。

## 5. VPS 安装与准备

### 5.1 上传公开工具包

先在**管理电脑**解压 ZIP。下列 `203.0.113.10` 必须换成新 VPS 的真实公网 IP：

```sh
scp -r ./vpn-reproduction-kit root@203.0.113.10:/root/
ssh root@203.0.113.10
```

工具包附带 `SHA256SUMS`，可在解压后的 `vpn-reproduction-kit` 目录检查文件是否完整：

```sh
# macOS：
shasum -a 256 -c SHA256SUMS
# Linux 可改为：sha256sum -c SHA256SUMS
```

这只能检查文件相对随包清单是否损坏，不是外部签名。`VALIDATION.md` 记录本次离线校验和本机临时握手测试的范围。

首次 SSH 登录应核对服务器控制台提供的主机指纹。遇到旧主机密钥冲突，先确认重装/更换原因，再更新该主机记录；不要使用关闭主机校验的参数绕过。

### 5.2 安装依赖并备份已有防火墙

在**VPS**运行：

```sh
sudo -i
apt-get update
apt-get install -y ca-certificates curl python3 openssl ufw
cd /root/vpn-reproduction-kit
umask 077
mkdir -p /root/vpn-setup-backup
cp -a /etc/ufw /root/vpn-setup-backup/ufw.before
cp -a /etc/default/ufw /root/vpn-setup-backup/ufw.defaults.before
ufw status verbose > /root/vpn-setup-backup/ufw-status.before.txt
iptables-save > /root/vpn-setup-backup/iptables.before
```

这些命令只针对新部署示例。已有备份时用新目录保存，避免覆盖上一次恢复点。没有 `iptables-save` 的系统可保存 `nft list ruleset`，但要按实际防火墙管理方式恢复。

### 5.3 下载与校验服务器二进制

在 **x86_64 VPS** 运行：

```sh
python3 scripts/download-xray.py \
  --asset Xray-linux-64.zip \
  --out /root/xray-server-download
install -m 755 /root/xray-server-download/xray /usr/local/bin/xray
/usr/local/bin/xray version
```

ARM64 VPS 将 asset 改为 `Xray-linux-arm64-v8a.zip`。下载目录已存在时脚本会拒绝覆盖，应检查后改用新目录。

下载器会从 XTLS 官方 GitHub release 下载 ZIP 与 `.dgst`，读取 `SHA2-256` 并逐字节校验，再提取指定二进制。这是同源文件完整性校验，不是独立发布者签名认证。不要把任意网站提供的二进制或摘要当成官方文件。

### 5.4 确认目标站点可用

在**VPS**运行：

```sh
openssl s_client \
  -connect www.asus.com:443 \
  -servername www.asus.com \
  -tls1_3 -alpn h2 </dev/null 2>/dev/null \
  | grep -E 'TLSv1.3|ALPN protocol|Verify return code'
```

至少应看到 TLS 1.3、`ALPN protocol: h2`、证书验证成功。命令挂起、没有输出或验证失败时先检查目标可达性、系统时间、CA、DNS；不要把失败的目标直接写进配置。目标站点和 CDN 行为可能变化，所以新服务器要重新测试，不能只照抄域名。

两端都应有正确的系统时间。路由器启用断线保护后，NTP 也只能经隧道；若开机时间严重错误导致握手失败，先通过 LAN 管理手动校准时间再启动隧道，不能临时放开整个 WAN 作为常规修复。正确的系统时间用于 TLS 证书等校验。`timedatectl status` 可检查时钟同步，但这与把显示时区改成美国是两件事。

## 6. 生成两端配置

### 6.1 生成新的 REALITY 密钥

在**VPS**运行：

```sh
cd /root/vpn-reproduction-kit
umask 077
/usr/local/bin/xray x25519 > /root/reality-keys.txt
chmod 600 /root/reality-keys.txt
```

26.10.29 的输出包含 `PrivateKey`、`Password (PublicKey)`、`Hash32`。客户端使用 `Password (PublicKey)`，不能用 Hash32 替代。私钥只留在服务器。

### 6.2 生成配置

把以下参数替换成第 4 节记录的真实值，在**VPS**运行：

```sh
python3 scripts/generate-configs.py \
  --vps-ip 203.0.113.10 \
  --sni www.asus.com \
  --key-file /root/reality-keys.txt \
  --wan-interface wan \
  --wan-dev wan \
  --lan-interface lan \
  --lan-dev br-lan \
  --wan6-interface wan6 \
  --lan-zone lan \
  --wan-zone wan \
  --tun-cidr 172.31.255.1/30 \
  --out /root/vpn-generated
```

**这里的 `203.0.113.10` 是文档保留地址，生成器会明确拒绝它；必须先填写自己的真实公网 IP。**

生成器只写文件，不会启动服务或修改网络。它会新建 UUID 和 Short ID，并把双方配置中的参数保持一致。输出目录已存在时拒绝覆盖，防止意外更换运行中的凭据。

输出结构：

```text
/root/vpn-generated/
├── server/
│   ├── config.json              # 含服务端私钥，仅服务器使用
│   ├── xray.service
│   └── 99-vpn-disable-ipv6.conf
└── router/
    ├── config.json              # 路由器正式配置
    ├── preflight.json           # 仅本机 SOCKS，切换前测试
    ├── us-vpn.init
    ├── 90-us-vpn-guard.nft
    ├── 99-us-vpn-ipv6.conf
    ├── site.env                 # 本地网络设备参数，无服务器私钥
    ├── apply-router.sh
    └── rollback-router.sh
```

JSON 里 `encryption: none` 是 VLESS 字段；外层 REALITY 仍提供加密，不表示公网明文传输。客户端 flow 使用 `xtls-rprx-vision-udp443`，服务端使用 `xtls-rprx-vision`，不要把字符串后缀随意统一。

## 7. 启动服务器、配置防火墙

### 7.1 安装服务端文件

在**VPS**运行；如果已有 `/usr/local/etc/xray/config.json` 或 `xray.service`，先停在这里备份和检查，不能直接覆盖：

```sh
adduser --system --group --no-create-home --disabled-login xray
install -d -m 750 -o root -g xray /usr/local/etc/xray
install -m 640 -o root -g xray \
  /root/vpn-generated/server/config.json \
  /usr/local/etc/xray/config.json
install -m 644 /root/vpn-generated/server/xray.service \
  /etc/systemd/system/xray.service
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
systemctl daemon-reload
systemctl enable --now xray
systemctl status xray --no-pager
ss -lntp
```

预期：`Configuration OK`、服务 active/running、443 有 Xray 监听。若 `xray` 用户已经存在，先确认它是预期的系统账户，不要盲目重建或修改其他服务的账户。

服务使用专用 xray 用户运行，保留绑定低端口所需的能力；不需要 `LoadCredential=`，因此也避开了原 Ubuntu 20.04/systemd 245 的兼容性问题。

模板服务端显式使用 IPv4 DNS 和出站策略，并在解析后匹配私网目标阻断规则。VPS 作为应用代理出站，不需要开启 Linux IP forwarding 或给它另加 MASQUERADE。

### 7.2 禁用服务器 IPv6

在**VPS**运行：

```sh
# 先记录原值，回滚时使用：
sysctl net.ipv6.conf.all.disable_ipv6 \
       net.ipv6.conf.default.disable_ipv6 \
  > /root/vpn-setup-backup/ipv6.before.txt
install -m 644 /root/vpn-generated/server/99-vpn-disable-ipv6.conf \
  /etc/sysctl.d/99-vpn-disable-ipv6.conf
sysctl -p /etc/sysctl.d/99-vpn-disable-ipv6.conf
ip -6 addr
ip -6 route
```

先确认服务器管理连接是 IPv4。已有同名 sysctl 文件时必须先备份。某些进程会保留 IPv6 形式的监听套接字，判断外部 IPv6 是否可用要结合内核值、地址和路由，不要仅凭 `ss` 中的 `[::]` 下结论。

### 7.3 放行管理端口后再启用防火墙

在**VPS**运行：

```sh
ufw show added
ufw status numbered
ufw default deny incoming
ufw default deny routed
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH management'
ufw allow 443/tcp comment 'VLESS REALITY'
ufw --force enable
ufw status verbose
```

在**管理电脑另开一个终端**，再次 `ssh root@你的VPS_IP`，确认新连接可以登录。原有会话不中断并不能证明新的 SSH 连接能通过防火墙。

注意：`default deny` 不会删除原有的 ALLOW 规则。新空白 VPS 最终应只有需要的 22/443 规则；有其他规则时用 `ufw status numbered` 逐条确认用途后删除，不能直接宣称只剩两个端口。已有业务端口应按实际需要保留。删除确认无用的旧规则时，先运行 `ufw status numbered`，再用 `ufw delete 对应编号`，每删一条重新列出编号，避免编号变化删错。若确有必要的其他应用，使用 `ufw allow 实际端口/tcp` 或对应 UDP 规则并记录理由。主机防火墙与供应商安全组是两层配置，都要检查。

## 8. 把路由器文件安全传过去

### 8.1 在 VPS 下载正确的路由器程序

以 **MT7621 路由器**为例，在**VPS**运行：

```sh
cd /root/vpn-reproduction-kit
python3 scripts/download-xray.py \
  --asset Xray-linux-mips32le.zip \
  --member xray_softfloat \
  --out /root/xray-router-download
```

ARM64 路由器使用 `--asset Xray-linux-arm64-v8a.zip --member xray`；其他型号按架构表选择。VPS 与路由器 CPU 可以不同，下载后不应在 VPS 上执行 MIPS 路由器程序。

### 8.2 通过管理电脑中转

在**管理电脑**创建独立目录，填入真实地址：

```sh
umask 077
mkdir vpn-transfer
cd vpn-transfer
scp -r root@203.0.113.10:/root/vpn-generated/router ./router-stage
scp root@203.0.113.10:/root/xray-router-download/xray ./xray-us-vpn
scp -O -r ./router-stage root@10.0.0.1:/root/us-vpn-stage
scp -O ./xray-us-vpn root@10.0.0.1:/tmp/xray-us-vpn
ssh root@10.0.0.1
```

`-O` 是 OpenSSH scp 的传统协议选项，用来兼容没有 SFTP 子系统的 Dropbear。这里需要大写字母 O，不是数字 0。如果你的 scp 实现不支持该参数，使用它支持的 SSH 文件传输方式，而不是改用公开 HTTP 分享凭据。

只中转 `router/`，不要把服务器 `server/config.json` 或 `/root/reality-keys.txt` 传到路由器。即使客户端没有服务器私钥，它的 UUID 等仍属于访问凭据，不能公开。

在**路由器**安装二进制：

```sh
chmod 755 /tmp/xray-us-vpn
/tmp/xray-us-vpn version
# 确认可运行后再放到持久存储：
cp /tmp/xray-us-vpn /usr/bin/xray-us-vpn
chmod 755 /usr/bin/xray-us-vpn
chmod 700 /root/us-vpn-stage
chmod 600 /root/us-vpn-stage/*.json /root/us-vpn-stage/site.env
/usr/bin/xray-us-vpn run -test -config /root/us-vpn-stage/config.json
```

运行报错时先解决架构、ABI 或配置问题，不要继续改防火墙。模板通过 `run -test` 只是语法/初始化检查，不代表实际握手或流量转发已成功。

## 9. 切换前的 SOCKS 连通性测试

这一步不会改默认路由或 LAN 转发。在**路由器**运行：

```sh
/usr/bin/xray-us-vpn run -test -config /root/us-vpn-stage/preflight.json
nohup /usr/bin/xray-us-vpn run \
  -config /root/us-vpn-stage/preflight.json \
  >/tmp/us-vpn-preflight.log 2>&1 </dev/null &
echo $! > /tmp/us-vpn-preflight.pid
```

确认进程已启动后：

```sh
curl -4fsS --max-time 25 \
  --proxy socks5h://127.0.0.1:2081 https://api.ipify.org
printf '\n'
curl -4fsS --max-time 25 \
  --proxy socks5h://127.0.0.1:2081 \
  https://www.cloudflare.com/cdn-cgi/trace
cat /tmp/us-vpn-preflight.log
```

必须看到你的新 VPS 出口 IPv4。若供应商做了公网 NAT，应先对照 VPS 自己访问同一查询服务得到的出口；出口不等于连接 IP 时，后续验收应以实际固定出站 IP 为准，不要误以为任意不同地址都正常。

发生 `reality verification failed` 时核对公钥、Short ID、UUID、SNI、端口、两端版本及目标站点，不要盲目关闭证书校验。本次原预装 sing-box 与 Xray 26.10.29 实测无法握手，换成两端相同 Xray 版本才通过。

确认测试成功后，在**路由器**停止这个临时实例并打标记：

```sh
# 先确认该 PID 仍对应刚才的 preflight.json 进程：
cat /tmp/us-vpn-preflight.pid
ps w | grep '[p]reflight.json'
# 确认后：
kill "$(cat /tmp/us-vpn-preflight.pid)"
touch /root/us-vpn-stage/preflight-ok
```

不要跳过测试后直接创建标记。正式部署不需要把 SOCKS 2081 开放给 LAN 或公网。

## 10. 路由器全局接管与自动回滚

### 10.1 应用前最后核对

在**路由器**运行：

```sh
cat /root/us-vpn-stage/site.env
uci changes
ip -4 route
```

`uci changes` 应没有输出；如果存在未提交修改，先确认并处理，脚本不会替你自动提交未知改动。所有 LAN 客户端会受切换影响，正在下载、通话或 SSH 的连接可能重连。

脚本会拒绝已存在的同名安装和名为 `vpn` 的既有防火墙区域。还应手动确认没有旧策略路由残留，没有其他管理程序不断重写防火墙。脚本的范围检查不能替代对复杂自定义固件的理解。

### 10.2 应用

在**路由器**通过 LAN SSH 运行：

```sh
sh /root/us-vpn-stage/apply-router.sh /root/us-vpn-stage
```

脚本按下列顺序执行：

1. 校验 OpenWrt、DHCP WAN、单默认路由、接口名、单 dnsmasq、TUN 和 Xray 配置。
2. 新建 `/root/us-vpn-backup-日期-时间/`，保存 network、firewall、dhcp、原 IPv6 内核状态及 UPnP 状态。
3. 安装 `/root/us-vpn-rollback.sh`，记录备份路径，并启动 **10 分钟自动恢复计时器**。
4. 安装正式 Xray 配置、procd 服务、nftables 阻断规则和 IPv6 sysctl 文件。
5. 关闭 LAN 的原区域转发，新增 LAN→VPN；关闭流量卸载和已存在的 Full Cone 选项。
6. 创建标准 fw4 TCP/UDP 53 重定向；若存在定制固件的 dns_redirect 选项，关闭它以避免重复接管。
7. 关闭 WAN6、IPv6 前缀分配、RA/DHCPv6/NDP；dnsmasq 只向本机 Xray 5353 请求 DNS。
8. 关闭 UPnP，加载防火墙，启动并启用 us-vpn，重启 dnsmasq。

脚本中途出错会尝试恢复。切换后网络不可用但 LAN SSH 仍可用时，可以立即执行回滚；如果连操作也无法继续，保持路由器通电，等待计时器恢复。**计时器只在当前启动周期有效，验收前不要重启或断电。**

### 10.3 十分钟内完成基本验收并确认

在**路由器**运行：

```sh
/etc/init.d/us-vpn status
ip -4 route
curl -4fsS --max-time 20 https://api.ipify.org
printf '\n'
nslookup example.com 127.0.0.1
nft list chain inet fw4 us_vpn_forward_guard
nft list chain inet fw4 us_vpn_output_guard
```

然后在一台 LAN 客户端访问外网，并确认出口是 VPS。成功后，在**路由器**运行：

```sh
B=$(cat /root/us-vpn-backup.current)
touch "$B/confirmed"
```

这个标记会取消自动回滚。没有确认标记，10 分钟后会恢复原配置，即使当前看起来能上网。不要在未验证时先打标记。剩余详细验收可以在确认后进行，手动回滚仍然可用。

### 10.4 为什么服务停了也不会泄漏

阻断规则直接属于 fw4，独立于 Xray：

- 转发 IPv6 一律丢弃。
- IPv4 转发只能流向 LAN 或 `us-tun`，不能去其他接口。
- 路由器自身只允许本地回环、LAN、TUN，以及 WAN→VPS:443、WAN DHCP。
- 其他出站流量丢弃。

规则使用比普通 fw4 filter 链更早的优先级，避免已有连接的快速放行绕过它；流量卸载同时关闭。手动停止 Xray 不等于恢复普通直连，需要明确执行回滚才能恢复。

这个严格策略也会阻止直接访问上级 WAN 网段里的管理设备。若需要访问光猫，必须自行明确设计仅针对光猫管理地址的例外，并重新检查 DNS、WebRTC 和断线行为；不要简单放开整个 WAN。

## 11. 逐项验收与断线测试

### 11.1 客户端先关闭二次代理

让 Mac/iPhone 连接这台路由器。先退出 Clash、其他 VPN 等软件，并检查系统代理是否实际关闭。浏览器出口与 STUN 出口不一致，常见原因就是二次代理。

在 **Mac** 查看：

```sh
scutil --proxy
route -n get 1.1.1.1
```

HTTPEnable、HTTPSEnable、SOCKSEnable 应为 0，默认网关应指向你的 OpenWrt。另有应用专属代理、环境变量代理、iCloud 中继或其他网络扩展时，也要单独确认。

### 11.2 HTTP 与目标服务出口

在**管理电脑/客户端**运行：

```sh
curl --noproxy '*' -4fsS --max-time 20 https://api.ipify.org
printf '\n'
curl --noproxy '*' -4fsS --max-time 20 \
  https://www.cloudflare.com/cdn-cgi/trace
curl --noproxy '*' -4fsS --max-time 20 \
  https://claude.ai/cdn-cgi/trace
curl --noproxy '*' -4fsS --max-time 20 \
  https://api.anthropic.com/cdn-cgi/trace
curl --noproxy '*' -4fsS --max-time 20 \
  https://platform.claude.com/cdn-cgi/trace
```

比较 `ip=`、`loc=`，应一致；Cloudflare 机房代码用于辅助观察，不应把某次 CDN 节点变化本身当成泄漏。403、验证码或账号错误与隧道是否连通不是同一个问题。

### 11.3 DNS

在**客户端**运行，替换路由器地址：

```sh
dig @10.0.0.1 example.com A +short +time=4 +tries=1
dig @8.8.8.8 example.com A +short +time=4 +tries=1
dig +tcp @8.8.8.8 example.com A +short +time=4 +tries=1
dig @10.0.0.1 example.com AAAA +short +time=4 +tries=1
```

A 查询应成功；经本路由器 DNS 的 AAAA 应被过滤。两项指定 8.8.8.8 的 DNS 查询会被标准 53 端口接管，除非设备使用另一个网络入口。dnsmasq 可以缓存结果，验证断线时要使用全新域名，不能只查询已经缓存的 example.com。

在**路由器**检查实际配置与规则：

```sh
uci show dhcp | grep -E 'server=|noresolv|filter_aaaa'
nft list ruleset | grep -E 'VPN-DNS|dport 53|redirect to :53'
```

浏览器打开 CleanIP 的检测，解析器应不出现本地宽带运营商。公共解析器本身可能用 IPv6 去访问权威 DNS；那是解析器的服务器地址，不等于你的客户端有 IPv6 出口。

### 11.4 STUN / WebRTC

在有 Python 3 的**管理电脑**，进入工具包目录运行：

```sh
python3 scripts/check-stun.py 你的VPS实际出口IPv4
```

脚本向 Google、Cloudflare 的公共 STUN 服务发 UDP 请求，打印每个返回的公网 IP 和是否匹配期望值。两个都匹配是独立于浏览器的补充证据；超时是“没有结果”，不能当作“确认无泄漏”。

再用浏览器访问 <https://cleanip.io/claude>，点击开始检测：

- WebRTC 的公网 IP 应与网页出口相同。
- 不应出现国内宽带公网 IP 或另一个国外代理 IP。
- 私有 LAN 地址、mDNS 名称与另一个公网出口不是一回事。
- DNS、IPv4/IPv6、各域名出口分别检查，不只看总分。

### 11.5 IPv6

在**路由器**运行：

```sh
sysctl net.ipv6.conf.all.disable_ipv6
sysctl net.ipv6.conf.default.disable_ipv6
ip -6 addr
ip -6 route
```

在 **Mac/Linux 客户端**运行：

```sh
curl --noproxy '*' -g -6fsS --connect-timeout 3 --max-time 5 \
  'https://[2606:4700:4700::1111]/cdn-cgi/trace'
```

该请求应失败；浏览器应未检测到 IPv6。不要仅用 `curl -6 https://某域名` 判断，因为某些系统会把 IPv4 地址映射成 `::ffff:` 形式，这仍可能是 IPv4 连接。必要时重连客户端 Wi-Fi，清除以前的 IPv6 地址和路由租约。

### 11.6 断线不直连：真实测试

先确认第 10.3 节已取消安装回滚计时器。测试期间全网会短暂不能上网。在**路由器**先安排恢复，再停止：

```sh
nohup sh -c 'sleep 30; /etc/init.d/us-vpn start' \
  >/tmp/us-vpn-recovery-test.log 2>&1 </dev/null &
/etc/init.d/us-vpn stop
```

立即在**客户端**运行：

```sh
curl --noproxy '*' --connect-timeout 3 --max-time 5 -fsS \
  https://1.1.1.1/cdn-cgi/trace
dig @8.8.8.8 "vpn-test-$(date +%s).example.com" A +time=2 +tries=1
```

HTTPS 应超时/失败。DNS 不应获得经 WAN 直接返回的正常公网解析；不同 dnsmasq 版本可能超时或直接 SERVFAIL，都要结合规则计数判断。NXDOMAIN 也可能来自缓存，所以使用新域名并检查计数。

在**路由器**查看：

```sh
nft list chain inet fw4 us_vpn_forward_guard
nft list chain inet fw4 us_vpn_output_guard
```

直接 WAN 流量的丢弃计数应增加，LAN SSH 管理仍应可用。30 秒后服务恢复，再次查询出口并做 STUN 测试。若恢复失败，用 LAN SSH 检查日志，必要时手动 `/etc/init.d/us-vpn start`。

### 11.7 持久化验收

依次做，不能同时重启两端：

1. 路由器 `/etc/init.d/us-vpn restart` 后验证出口。
2. 路由器 `/etc/init.d/firewall reload` 后验证出口及断线阻断链。
3. 检查 `/etc/rc.d/` 中 us-vpn 链接，VPS `systemctl is-enabled xray` 应为 enabled。
4. 在有现场恢复条件时重启路由器，确认 WAN 获取地址、LAN DHCP、DNS、TUN、IPv6 和断线保护全部恢复。
5. 路由器稳定后，再重启 VPS，确认 SSH 和隧道服务都能恢复。

原项目做过服务重启、防火墙重载和断线测试，**没有做整机重启测试**。新机器安装后的重启验收需要你实际执行并记录，不能照抄旧测试结论。

## 12. Mac / iPhone 的使用要求

### 12.1 Mac

连接该路由器的 Wi-Fi 或 LAN，网关和 DNS 使用自动分配。退出本地 Clash 后，再检查系统代理开关，而不是只看菜单栏图标是否消失。

如确实需要手工关闭系统代理，先用 `networksetup -listallnetworkservices` 找到当前服务名；然后在 Mac 上对实际网络服务执行：

```sh
networksetup -setwebproxystate 'Wi-Fi' off
networksetup -setsecurewebproxystate 'Wi-Fi' off
networksetup -setsocksfirewallproxystate 'Wi-Fi' off
scutil --proxy
```

如果当前使用 Ethernet，应替换服务名。这些命令不负责关闭应用自己设置的代理。不要为验证而公开打印包含认证信息的代理环境变量。

### 12.2 iPhone

1. 连接 OpenWrt 提供的 Wi-Fi，检查路由器地址是否正确。
2. 关闭其他 VPN/代理应用后测试；Wi-Fi 的 HTTP 代理通常设为关闭。
3. 若使用 iCloud 专用代理或该 Wi-Fi 的“限制 IP 地址跟踪”，Safari 可能再次经 Apple 中转。要求所有出口一致时，需要在该网络上自行调整并复测。
4. 测试时不要切到蜂窝网络；要排除蜂窝回落，可临时开启飞行模式后单独打开 Wi-Fi。
5. 在 Safari 重新运行检测。Mac 的通过结果不能替代 iPhone 的验证。

### 12.3 时区与语言

本方案不会自动修改终端语言、地区或时区。原用户选择保留，因此“上海时区 + 美国出口”的提示保留。若以后主动调整，应使用 `America/Los_Angeles` 等地理时区以自动处理夏令时，不能简单固定 UTC-8。改变设备设置会影响日历、日期格式和显示习惯，需要单独决定。

## 13. 日常管理、更新与重启

### 13.1 路由器

```sh
/etc/init.d/us-vpn status
logread -e xray
/etc/init.d/us-vpn restart
ip -4 route
nft list chain inet fw4 us_vpn_output_guard
```

这是独立服务，不在 PassWall 节点列表中管理。不要另行开启 PassWall、OpenClash 等接管同一流量。LuCI 修改防火墙之后，仍应确认自定义 nftables 文件被加载。

### 13.2 VPS

```sh
systemctl status xray --no-pager
journalctl -u xray -n 50 --no-pager
systemctl restart xray
systemctl is-enabled xray
ufw status verbose
```

访问日志默认关闭，警告/错误保留。排查时可以短暂提高日志级别，定位后改回；不要把带 UUID、密钥或用户访问详情的完整日志公开发布。

如果你的 SSH 自己正通过这个隧道连接 VPS，重启服务器 Xray 会让该 SSH 会话中断。远程执行的后续命令可能没运行完，所以应重新登录核实；不要把连接断开误判为服务器必然启动失败。

### 13.3 最终安装位置与端口清单

| 位置 | 文件或服务 | 用途 |
|---|---|---|
| VPS | `/usr/local/bin/xray` | Xray 程序 |
| VPS | `/usr/local/etc/xray/config.json` | VLESS/REALITY 服务端，含私钥 |
| VPS | `/etc/systemd/system/xray.service` | 专用账户运行及开机启动 |
| VPS | `/etc/sysctl.d/99-vpn-disable-ipv6.conf` | 持久化禁用 IPv6 |
| VPS | `/etc/ufw/` | 默认拒绝入站，放行必要端口 |
| VPS | `/root/vpn-setup-backup/` | 安装前防火墙与 IPv6 记录 |
| 路由器 | `/usr/bin/xray-us-vpn` | 匹配路由器 CPU 的程序 |
| 路由器 | `/etc/us-vpn/config.json` | TUN、DNS 入站及 VPS 出站 |
| 路由器 | `/etc/init.d/us-vpn` | procd 服务、自动重启及开机启动 |
| 路由器 | `/etc/nftables.d/90-us-vpn-guard.nft` | 防止直连和 IPv6 泄漏 |
| 路由器 | `/etc/sysctl.d/99-us-vpn-ipv6.conf` | 持久化禁用 IPv6 |
| 路由器 | `/etc/config/network` | 关闭 WAN6、IPv6 分配和运营商 DNS |
| 路由器 | `/etc/config/firewall` | VPN 区域、转发、DNS 接管与卸载选项 |
| 路由器 | `/etc/config/dhcp` | dnsmasq 上游、AAAA 过滤、RA/DHCPv6/NDP |
| 路由器 | `/root/us-vpn-backup-日期-时间/` | 这次安装对应的原状态和确认标记 |
| 路由器 | `/root/us-vpn-backup.current`、`/root/us-vpn-rollback.sh` | 备份定位与回滚入口 |

| 端口 | 监听/访问范围 | 是否长期保留 |
|---|---|---|
| VPS TCP 22 | SSH 管理入口 | 保留；可另行按管理来源限制 |
| VPS TCP 443 | REALITY 隧道入口 | 保留 |
| 路由器 TCP/UDP 53 | LAN 使用的 dnsmasq | 保留，遵循原 LAN 管理防火墙 |
| 路由器 127.0.0.1 TCP/UDP 5353 | Xray DNS 隧道入站 | 保留，仅回环 |
| 路由器 127.0.0.1 TCP 2081 | 安装前 SOCKS 测试 | 测试后停止，不对外开放 |

这里没有新增 VPS 上的公开 SOCKS/HTTP 代理端口，也不需要开放公网 UDP 53、2081 或 5353。路由器原有 LAN SSH/LuCI 管理服务继续按原规则运行。

安装中间目录含客户端凭据；不要传到公共网盘或代码仓库。验收后可以加密归档，管理电脑的 `vpn-transfer` 和路由器的 `/root/us-vpn-stage` 不再用于正式服务，但应先确认正式文件安装完整，再清理这些中间副本。保留恢复备份与对应版本号。

### 13.4 更新

先备份两端二进制、配置和服务文件，再在测试条件下确认新版本兼容。不要重新运行生成器覆盖旧 UUID/密钥来进行普通升级；更新程序与轮换凭据是不同操作。

更新前后都要做 `run -test`、真实 SOCKS/隧道请求、DNS/STUN/IPv6 验证。若升级失败，恢复旧二进制和旧配置并重启服务。对于资源有限的路由器，下载、解压可以放在 VPS/管理电脑进行，避免 /tmp 内存不足。

## 14. 回滚与恢复

### 14.1 路由器一键恢复

在**路由器 LAN SSH**运行：

```sh
sh /root/us-vpn-rollback.sh
```

它会停止并禁用 us-vpn、移除本次防泄漏和 IPv6 sysctl 文件、恢复 network/firewall/dhcp、恢复原 IPv6 内核值及原 UPnP 状态，并重新加载服务。恢复后会重新具有安装前的直连/IPv6 行为，**不再具有本次断线保护**。

脚本保留备份、二进制、停用的服务文件和配置供检查，不会删除原始恢复证据。确认无误后再决定是否归档这些文件。重新安装不能直接重复运行新安装脚本，应先核对残留文件并移走已停用的本次专用文件，不能删除其他服务的目录来“清理”。

本工具包的恢复脚本与原机器上的旧恢复脚本有细节差异：工具包记录并恢复原 UPnP/IPv6 状态；原实例的专用恢复脚本按那台机器的已知原始状态恢复。不要交叉替换两套备份目录。

### 14.2 VPS 恢复

先确保路由器已经恢复直连，或还有其他管理路径。VPS 上可以先停止并禁用新安装的服务：

```sh
systemctl disable --now xray
```

然后按部署前记录恢复 UFW 和 IPv6：

- `/root/vpn-setup-backup/ufw.before/` 是原 UFW 规则配置。
- `ufw.defaults.before` 是 `/etc/default/ufw`，包括原默认策略，也必须恢复。
- `ufw-status.before.txt` 记录原来是否启用。
- `ipv6.before.txt` 记录原内核值。
- 新安装的 `/etc/sysctl.d/99-vpn-disable-ipv6.conf` 应移走或恢复原版本，再应用原来的内核值。

不要在生产服务器上不加区分地 `ufw reset` 或清空整个 nftables/iptables 规则集。如果原 UFW 是关闭的，恢复后可关闭 UFW；如果原来开启，恢复原规则并重载。先保住新的 SSH 连接，再关闭旧会话。

对于本手册的全新 UFW 安装，以下是**先检查后执行**的恢复示例；若使用了不同的备份目录，替换路径。先确认备份内是原 `ufw.conf`、`user.rules` 等文件，而非多嵌套一层目录：

```sh
# VPS，保留当前 SSH 会话，并准备供应商控制台：
ls -la /root/vpn-setup-backup/ufw.before/
cat /root/vpn-setup-backup/ufw-status.before.txt
cat /root/vpn-setup-backup/ipv6.before.txt
# 核对无误后，恢复原 UFW 文件：
cp -a /root/vpn-setup-backup/ufw.before/. /etc/ufw/
cp -a /root/vpn-setup-backup/ufw.defaults.before /etc/default/ufw
# 原状态是 active 时执行：
ufw reload
# 原状态是 inactive 时，应改为执行 ufw disable，不要两条一起运行。
```

恢复 IPv6 时，先移走本次新建的 sysctl 文件；**仅当此文件是本手册新建且原来不存在**时使用：

```sh
mv /etc/sysctl.d/99-vpn-disable-ipv6.conf \
  /root/vpn-setup-backup/99-vpn-disable-ipv6.conf.removed
# 使用备份中的原值，而不是固定设为 0：
sysctl -p /root/vpn-setup-backup/ipv6.before.txt
```

有同名旧文件时应恢复旧文件，而不是直接移走。若原网络还依赖 IPv6 DHCP/RA，恢复内核值后可能需要对应网络服务重新获取地址；在控制台中按发行版网络管理方式处理。UFW 恢复后仍要新开 SSH 验证，再关闭旧会话。

删除 xray 用户之前确认它没有被其他服务使用。没有必要仅为了停止 VPN 就删除用户或软件包。

## 15. 常见问题与排查顺序

| 现象 | 优先检查 | 处理方向 |
|---|---|---|
| Illegal instruction | CPU、大小端、硬/软浮点 | MT7621 提取 `xray_softfloat` |
| Exec format error | 使用了另一架构的程序 | 按发行版架构重新下载 |
| `/dev/net/tun` 不存在 | kmod-tun、内核匹配 | 安装与当前固件匹配的模块 |
| `unknown field` / 配置不支持 | 两端 Xray 版本 | 对照锁定版本，不照抄其他版本字段 |
| `invalid public_key` / 握手失败 | 公钥是否误读、Hash32 是否误用 | 使用 `Password (PublicKey)`，核对 UUID/SNI/Short ID |
| `reality verification failed` | 两端内核兼容性、SNI、目标站点 | 本次两端同版本 Xray 通过；不要仅反复改时间 |
| SOCKS 成功、全局失败 | WAN_DEV、TUN 路由、fw4 VPN 区域 | 对照 `l3_device`、路由和防火墙链 |
| 能连 IP、打不开域名 | dnsmasq→5353、Xray 服务、CA | 检查本地 DNS 链路，不能改回运营商 DNS 来掩盖问题 |
| 浏览器与 STUN 地址不同 | 本地代理、iCloud 中继、扩展 | 关闭二次代理后重新验证 |
| `curl -6` 似乎仍成功 | 是否实际连接 `::ffff:` 地址 | 使用字面量 IPv6 地址验证 |
| 一开始正常，十分钟后恢复 | 没有创建 confirmed 标记 | 检查回滚日志，重新按步骤部署 |
| 停止服务后仍能上网 | 自定义规则没加载、其他网络接口、流量卸载 | 先停止使用该环境，修复阻断再验收 |
| 重启后 DNS/隧道未启动 | 开机服务、WAN DHCP、时间、日志 | 先用 LAN SSH 排查，不直接放开 WAN 回退 |
| 443 超时 | 云安全组、UFW、服务监听、运营商线路 | 从路由器与外部独立网络分别检查 |
| 国内网站慢 | 所有流量经美国、路由器 CPU | 这是全球统一出口的代价，不能靠假测速消除 |
| 本地软件仍显示地区/代理迹象 | 语言时区、定位权限、账号、IP 分类 | 网络层通过不等于应用层身份或环境不可识别 |

故障排查顺序建议：物理网络和 WAN → SSH/443 可达性 → Xray 程序架构 → JSON 校验 → SOCKS 真实握手 → TUN 路由 → DNS → 防火墙 → 浏览器和设备本地代理。

## 16. 原部署结果、模板差异与验证边界


原实机：x x x VPS；MT7621、约 241 MiB 内存的 Kwrt 路由器；Xray 两端 26.10.29。已经实测统一 IPv4 出口、Google/Cloudflare STUN、浏览器 WebRTC/DNS、IPv6 阻断、停止隧道后的禁止直连、服务重启及防火墙重载。退出 Mac 本地 Clash 后再次验证正常。

这次为迁移制作的模板并非把那台机器的配置原样打包，做了明确的通用化：

- 用参数替代固定 VPS、LAN、WAN 地址与设备名，每次生成新凭据。
- 不依赖 `@forwarding[0]` 这种可能指向错误项目的数组下标，通过区域名找转发项。
- 在没有 Kwrt 自带 DNS 接管选项的机器上，显式建立标准 TCP/UDP 53 重定向。
- 防泄漏规则采用允许的接口集合，未列出的接口默认不能出站；因此适用范围明确限制为单 WAN/单 LAN。
- 保存原 IPv6 和 UPnP 状态，提供安装错误恢复及未确认自动回滚。
- 服务端增加显式 IPv4 DNS 与解析后私网规则匹配，避免仅对字面 IP 进行匹配。

这些通用化脚本需要在每台新机器上完成第 11 节验收。原实机通过不等于所有固件、所有架构都通过。脚本检查和离线配置校验也不等于端到端网络验收。

## 17. 完整配置附录与参考资料

下面列出工具包中的完整模板及脚本。正文的生成器会替换 `__TOKEN__`，**不要直接运行尚未替换的模板**。以同目录文件为准，阅读器复制代码时不要遗漏引号、换行或 here-document 结束标记。

参考资料（2026-10-31 核对）：

- [Xray v26.10.29 官方发布](https://github.com/XTLS/Xray-core/releases/tag/v26.10.29)
- [官方构建流程及 MIPS soft-float 构建](https://raw.githubusercontent.com/XTLS/Xray-core/v26.10.29/.github/workflows/release.yml)
- [Xray TUN 配置](https://xtls.github.io/en/config/inbounds/tun.html)
- [REALITY 配置](https://xtls.github.io/en/config/transports/reality.html)
- [VLESS 出站](https://xtls.github.io/en/config/outbounds/vless.html)
- [Tunnel 入站](https://xtls.github.io/en/config/inbounds/tunnel.html)
- [OpenWrt UCI shell 辅助函数源码](https://raw.githubusercontent.com/openwrt/openwrt/master/package/base-files/files/lib/functions.sh)
- [OpenWrt firewall4 自定义规则说明](https://github.com/openwrt/firewall4/blob/master/root/usr/share/nftables.d/README)
- [CleanIP 检测与评分说明](https://cleanip.io/claude)

### 17.1 `templates/server.json`

```json
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "__UUID__",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "__SNI__:443",
          "xver": 0,
          "serverNames": [
            "__SNI__"
          ],
          "privateKey": "__PRIVATE_KEY__",
          "shortIds": [
            "__SHORT_ID__"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {},
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "UseIPv4"
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "ip": [
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "224.0.0.0/4",
          "240.0.0.0/4",
          "::/0"
        ],
        "outboundTag": "block"
      }
    ]
  },
  "dns": {
    "servers": [
      "1.1.1.1"
    ],
    "queryStrategy": "UseIPv4"
  }
}
```

### 17.2 `templates/router.json`

```json
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "inbounds": [
    {
      "tag": "tun-in",
      "protocol": "tun",
      "settings": {
        "name": "us-tun",
        "mtu": 1400,
        "gateway": [
          "__TUN_CIDR__"
        ],
        "autoSystemRoutingTable": [
          "0.0.0.0/1",
          "128.0.0.0/1"
        ],
        "autoOutboundsInterface": "__WAN_DEV__"
      }
    },
    {
      "tag": "dns-in",
      "listen": "127.0.0.1",
      "port": 5353,
      "protocol": "tunnel",
      "settings": {
        "address": "1.1.1.1",
        "port": 53,
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "us-vpn",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "__VPS_IPV4__",
            "port": 443,
            "users": [
              {
                "id": "__UUID__",
                "encryption": "none",
                "flow": "xtls-rprx-vision-udp443"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "serverName": "__SNI__",
          "fingerprint": "chrome",
          "password": "__PUBLIC_KEY__",
          "shortId": "__SHORT_ID__"
        },
        "sockopt": {
          "interface": "__WAN_DEV__",
          "tcpKeepAliveIdle": 60
        }
      }
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "connIdle": 300
      }
    }
  }
}
```

### 17.3 `templates/xray.service`

```ini
[Unit]
Description=VLESS REALITY VPN server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=xray
Group=xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
```

### 17.4 `templates/us-vpn.init`

```sh
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/xray-us-vpn run -config /etc/us-vpn/config.json
    procd_set_param respawn 3600 5 0
    procd_set_param file /etc/us-vpn/config.json
    procd_set_param limits nofile="65535 65535"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
```

### 17.5 `templates/99-us-vpn-ipv6.conf`

```ini
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
```

### 17.6 `templates/90-us-vpn-guard.nft`

```nft
# Included INSIDE table inet fw4 by /etc/nftables.d/*.nft.
chain us_vpn_forward_guard {
    type filter hook forward priority -5; policy accept;
    meta nfproto ipv6 counter drop comment "VPN: no forwarded IPv6"
    oifname != { "__LAN_DEV__", "us-tun" } counter drop comment "VPN: no direct forwarding"
}
chain us_vpn_output_guard {
    type filter hook output priority -5; policy accept;
    meta nfproto ipv6 counter drop comment "VPN: no router IPv6"
    oifname { "lo", "__LAN_DEV__", "us-tun" } accept
    oifname "__WAN_DEV__" ip daddr __VPS_IPV4__ tcp dport 443 counter accept comment "VPN uplink"
    oifname "__WAN_DEV__" udp sport 68 udp dport 67 counter accept comment "WAN DHCP"
    counter drop comment "VPN: no other router egress"
}
```

### 17.7 `scripts/download-xray.py`

```python
#!/usr/bin/env python3
"""Download a pinned official asset, verify its SHA256, extract only a binary."""
import argparse,hashlib,pathlib,re,urllib.request,zipfile
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--asset',required=True,help='e.g. Xray-linux-64.zip')
p.add_argument('--member',default='xray',choices=['xray','xray_softfloat'])
p.add_argument('--version',default='v26.10.29')
p.add_argument('--out',required=True)
a=p.parse_args()
if not re.fullmatch(r'v\d+\.\d+\.\d+',a.version):p.error('Invalid version')
if not re.fullmatch(r'Xray-[A-Za-z0-9_-]+\.zip',a.asset):p.error('Invalid asset name')
out=pathlib.Path(a.out)
if out.exists():p.error('Output directory already exists; use a new directory')
out.mkdir(parents=True,mode=0o700)
base=f'https://github.com/XTLS/Xray-core/releases/download/{a.version}/{a.asset}'
for suffix in ('','.dgst'):
 req=urllib.request.Request(base+suffix,headers={'User-Agent':'vpn-reproduction-kit/1'})
 with urllib.request.urlopen(req,timeout=90) as src,(out/(a.asset+suffix)).open('wb') as dst:
  while True:
   b=src.read(1024*1024)
   if not b:break
   dst.write(b)
digest=(out/(a.asset+'.dgst')).read_text()
m=re.search(r'^SHA2-256=\s*([0-9a-fA-F]{64})\s*$',digest,re.M)
if not m:raise SystemExit('SHA2-256 entry missing; stop and inspect the official digest format')
h=hashlib.sha256()
with (out/a.asset).open('rb') as f:
 for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
if h.hexdigest()!=m.group(1).lower():raise SystemExit('SHA256 mismatch; binary NOT extracted')
with zipfile.ZipFile(out/a.asset) as z:
 if a.member not in z.namelist():raise SystemExit('Requested binary missing; inspect archive members')
 (out/'xray').write_bytes(z.read(a.member))
(out/'xray').chmod(0o755)
(out/'SHA256.txt').write_text(h.hexdigest()+'  '+a.asset+'\n')
print('Verified official archive SHA256:',h.hexdigest())
print('Extracted binary:',out/'xray')
```

### 17.8 `scripts/generate-configs.py`

```python
#!/usr/bin/env python3
"""Generate fresh credentials and config files. Never modifies a host's network."""
import argparse,base64,ipaddress,json,os,pathlib,re,secrets,shlex,uuid
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--vps-ip',required=True)
p.add_argument('--sni',required=True)
p.add_argument('--key-file',required=True,help='Output of xray x25519')
p.add_argument('--wan-dev',required=True,help='Linux L3 device, not UCI interface name')
p.add_argument('--lan-dev',default='br-lan')
p.add_argument('--wan-interface',default='wan')
p.add_argument('--lan-interface',default='lan')
p.add_argument('--wan6-interface',default='wan6')
p.add_argument('--lan-zone',default='lan')
p.add_argument('--wan-zone',default='wan')
p.add_argument('--tun-cidr',default='172.31.255.1/30')
p.add_argument('--out',required=True)
a=p.parse_args();os.umask(0o077)
try:
 ip=ipaddress.IPv4Address(a.vps_ip)
 if not ip.is_global:p.error('Use your real public IPv4, not a documentation/private address')
 tun=ipaddress.IPv4Interface(a.tun_cidr)
 if tun.network.prefixlen!=30 or not any(tun.ip in ipaddress.IPv4Network(net) for net in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')) or tun.ip in (tun.network.network_address,tun.network.broadcast_address):p.error('TUN must be a private usable /30 address')
except ValueError as e:p.error(str(e))
for val in (a.wan_dev,a.lan_dev,a.wan_interface,a.lan_interface,a.wan6_interface,a.lan_zone,a.wan_zone):
 if not re.fullmatch(r'[A-Za-z0-9_.-]{1,32}',val):p.error('Invalid interface/zone name')
if a.lan_zone==a.wan_zone or 'vpn' in (a.lan_zone,a.wan_zone):p.error('LAN/WAN zones must be distinct and cannot use reserved name vpn')
if a.wan_dev==a.lan_dev or a.lan_dev=='us-tun' or a.wan_dev=='us-tun':p.error('Interface names must be distinct')
if len(a.sni)>253 or not re.fullmatch(r'(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?',a.sni) or '.' not in a.sni:p.error('SNI must be a DNS hostname, without scheme or port')
k={}
for line in pathlib.Path(a.key_file).read_text().splitlines():
 if ':' in line:
  name,val=line.split(':',1);k[name.strip()]=val.strip()
private=k.get('PrivateKey');public=k.get('Password (PublicKey)') or k.get('PublicKey') or k.get('Password')
for val in (private,public):
 if not val or not re.fullmatch(r'[A-Za-z0-9_-]{43}',val) or len(base64.urlsafe_b64decode(val+'='))!=32:p.error('Invalid/missing X25519 key; use xray x25519 output')
out=pathlib.Path(a.out)
if out.exists():p.error('Output directory exists; refusing to overwrite credentials')
out.mkdir(parents=True,mode=0o700)
root=pathlib.Path(__file__).resolve().parent.parent
mapping={'__VPS_IPV4__':a.vps_ip,'__SNI__':a.sni,'__PRIVATE_KEY__':private,'__PUBLIC_KEY__':public,'__UUID__':str(uuid.uuid4()),'__SHORT_ID__':secrets.token_hex(8),'__WAN_DEV__':a.wan_dev,'__LAN_DEV__':a.lan_dev,'__TUN_CIDR__':a.tun_cidr}
def render(name):
 s=(root/'templates'/name).read_text()
 for key,val in mapping.items():s=s.replace(key,val)
 if re.search(r'__[A-Z0-9_]+__',s):raise ValueError('Unresolved template token')
 return s
def write(name,s):
 q=out/name;q.parent.mkdir(parents=True,exist_ok=True,mode=0o700);q.write_text(s);q.chmod(0o600)
for dest,source in [('server/config.json','server.json'),('server/xray.service','xray.service'),('server/99-vpn-disable-ipv6.conf','99-us-vpn-ipv6.conf'),('router/config.json','router.json'),('router/us-vpn.init','us-vpn.init'),('router/90-us-vpn-guard.nft','90-us-vpn-guard.nft'),('router/99-us-vpn-ipv6.conf','99-us-vpn-ipv6.conf')]:write(dest,render(source))
config=json.loads((out/'router/config.json').read_text())
config['inbounds']=[{'tag':'preflight','listen':'127.0.0.1','port':2081,'protocol':'socks','settings':{'auth':'noauth','udp':True,'ip':'127.0.0.1'}}]
write('router/preflight.json',json.dumps(config,indent=2)+'\n')
params={'VPS_IP':a.vps_ip,'WAN_DEV':a.wan_dev,'LAN_DEV':a.lan_dev,'WAN_IF':a.wan_interface,'LAN_IF':a.lan_interface,'WAN6_IF':a.wan6_interface,'LAN_ZONE':a.lan_zone,'WAN_ZONE':a.wan_zone}
write('router/site.env',''.join(key+'='+shlex.quote(val)+'\n' for key,val in params.items()))
for name in ('apply-router.sh','rollback-router.sh'):
 write('router/'+name,(root/'scripts'/name).read_text())
print('Generated fresh UUID and Short ID. Server private key remains in server/ only.')
print('Transfer only the router/ directory to the router. Output:',out)
```

### 17.9 `scripts/apply-router.sh`

```sh
#!/bin/sh
# Fresh-install helper for ONE DHCP WAN + ONE LAN on OpenWrt/fw4.
# Read README first. This script changes routing, DNS and firewall.
set -e
# OpenWrt UCI shell helpers use optional unset variables; do not enable nounset.
STAGE=${1:-/root/us-vpn-stage}
fail() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'Run as root on the ROUTER'
[ -r /etc/openwrt_release ] || fail 'Not an OpenWrt router'
for cmd in uci ubus jsonfilter nft fw4 ip sysctl nohup; do command -v "$cmd" >/dev/null || fail "Missing $cmd"; done
[ -r "$STAGE/site.env" ] || fail 'Missing generated site.env'
[ -f "$STAGE/preflight-ok" ] || fail 'Complete SOCKS test, then create preflight-ok in this stage directory'
. "$STAGE/site.env"
: "${VPS_IP:?}" "${WAN_IF:?}" "${WAN_DEV:?}" "${LAN_IF:?}" "${LAN_DEV:?}" "${WAN6_IF:?}" "${LAN_ZONE:?}" "${WAN_ZONE:?}"
[ ! -e /etc/init.d/us-vpn ] || fail 'us-vpn exists; this is not an upgrade script'
[ ! -e /etc/us-vpn ] || fail '/etc/us-vpn already exists'
[ ! -e /etc/nftables.d/90-us-vpn-guard.nft ] || fail 'Guard file exists'
[ ! -e /etc/sysctl.d/99-us-vpn-ipv6.conf ] || fail 'IPv6 file exists'
[ ! -e /root/us-vpn-rollback.sh ] || fail 'Rollback script exists; inspect previous installation'
[ ! -e /root/us-vpn-backup.current ] || fail 'Backup pointer exists; inspect previous installation'
[ "$(uci -q get network."$WAN_IF".proto)" = dhcp ] || fail 'Helper supports DHCP WAN only'
[ "$(uci -q get network."$LAN_IF".proto)" = static ] || fail 'Helper requires static LAN'
[ "$(uci -q get dhcp."$LAN_IF")" = dhcp ] || fail 'DHCP section must use LAN_IF name; adapt script for other layouts'
actual_wan=$(ubus call network.interface."$WAN_IF" status | jsonfilter -e '@.l3_device')
actual_lan=$(ubus call network.interface."$LAN_IF" status | jsonfilter -e '@.l3_device')
[ "$actual_wan" = "$WAN_DEV" ] || fail 'WAN_DEV does not match live L3 device'
[ "$actual_lan" = "$LAN_DEV" ] || fail 'LAN_DEV does not match live L3 device'
[ "$(ip -4 route show default | wc -l | tr -d ' ')" = 1 ] || fail 'Expected one IPv4 default route'
[ "$(uci show dhcp | sed -n '/=dnsmasq$/p' | wc -l | tr -d ' ')" = 1 ] || fail 'Multiple/missing dnsmasq instances'
[ -c /dev/net/tun ] || fail 'Missing TUN kernel device'
[ -x /usr/bin/xray-us-vpn ] || fail 'Missing Xray binary'
[ -z "$(uci changes)" ] || fail 'Commit or revert existing pending UCI changes first'
for item in us_vpn lan_us_vpn us_vpn_dns; do
 if uci -q get firewall."$item" >/dev/null; then fail "firewall.$item already exists"; fi
done
. /lib/functions.sh
LAN_FOUND=0
WAN_FOUND=0
VPN_FOUND=0
check_zone() {
 local section="$1" name
 config_get name "$section" name
 [ "$name" != "$LAN_ZONE" ] || LAN_FOUND=$((LAN_FOUND+1))
 [ "$name" != "$WAN_ZONE" ] || WAN_FOUND=$((WAN_FOUND+1))
 [ "$name" != vpn ] || VPN_FOUND=$((VPN_FOUND+1))
}
config_load firewall
config_foreach check_zone zone
[ "$LAN_FOUND" = 1 ] && [ "$WAN_FOUND" = 1 ] || fail 'LAN/WAN zone names must each identify exactly one zone'
[ "$VPN_FOUND" = 0 ] || fail 'A firewall zone named vpn already exists'
/usr/bin/xray-us-vpn run -test -config "$STAGE/config.json"
# Ensure the chosen TUN subnet does not overlap existing networks BEFORE running.
umask 077
B="/root/us-vpn-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$B"
for f in network firewall dhcp; do cp -p "/etc/config/$f" "$B/$f"; done
for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
 [ ! -r "$path" ] || printf '%s %s\n' "$path" "$(cat "$path")" >> "$B/ipv6-state"
done
if [ -x /etc/init.d/miniupnpd ]; then
 /etc/init.d/miniupnpd enabled >/dev/null 2>&1 && touch "$B/upnp-enabled" || true
 pidof miniupnpd >/dev/null 2>&1 && touch "$B/upnp-running" || true
fi
printf '%s\n' "$B" > /root/us-vpn-backup.current
cp "$STAGE/rollback-router.sh" /root/us-vpn-rollback.sh
chmod 700 /root/us-vpn-rollback.sh
# Errors after this point trigger restoration. A second timer covers disconnection.
trap 'rc=$?; trap - EXIT; if [ "$rc" -ne 0 ]; then sh /root/us-vpn-rollback.sh; fi; exit "$rc"' EXIT
cat > "$B/autorevert.sh" <<'EOF'
#!/bin/sh
sleep 600
B=$(cat /root/us-vpn-backup.current)
if [ ! -f "$B/confirmed" ] && [ ! -f "$B/rolled-back" ]; then
 sh /root/us-vpn-rollback.sh > "$B/autorevert.log" 2>&1
fi
EOF
nohup sh "$B/autorevert.sh" > "$B/timer.log" 2>&1 </dev/null &
mkdir -p /etc/us-vpn /etc/nftables.d /etc/sysctl.d
chmod 700 /etc/us-vpn
cp "$STAGE/config.json" /etc/us-vpn/config.json
chmod 600 /etc/us-vpn/config.json
cp "$STAGE/us-vpn.init" /etc/init.d/us-vpn
chmod 755 /etc/init.d/us-vpn
cp "$STAGE/90-us-vpn-guard.nft" /etc/nftables.d/90-us-vpn-guard.nft
cp "$STAGE/99-us-vpn-ipv6.conf" /etc/sysctl.d/99-us-vpn-ipv6.conf
update_defaults() {
 local section="$1"
 uci set firewall."$section".flow_offloading='0'
 uci set firewall."$section".flow_offloading_hw='0'
 if uci -q get firewall."$section".fullcone >/dev/null; then uci set firewall."$section".fullcone='0'; fi
 if uci -q get firewall."$section".fullcone6 >/dev/null; then uci set firewall."$section".fullcone6='0'; fi
}
disable_forwarding() {
 local section="$1" src
 config_get src "$section" src
 if [ "$src" = "$LAN_ZONE" ]; then uci set firewall."$section".enabled='0'; fi
}
config_load firewall
config_foreach update_defaults defaults
config_foreach disable_forwarding forwarding
uci set firewall.us_vpn=zone
uci set firewall.us_vpn.name='vpn'
uci add_list firewall.us_vpn.device='us-tun'
uci set firewall.us_vpn.input='REJECT'
uci set firewall.us_vpn.output='ACCEPT'
uci set firewall.us_vpn.forward='REJECT'
uci set firewall.lan_us_vpn=forwarding
uci set firewall.lan_us_vpn.src="$LAN_ZONE"
uci set firewall.lan_us_vpn.dest='vpn'
uci set firewall.us_vpn_dns=redirect
uci set firewall.us_vpn_dns.name='VPN-DNS-to-router'
uci set firewall.us_vpn_dns.src="$LAN_ZONE"
uci set firewall.us_vpn_dns.proto='tcp udp'
uci set firewall.us_vpn_dns.src_dport='53'
uci set firewall.us_vpn_dns.dest_port='53'
uci set firewall.us_vpn_dns.family='ipv4'
uci set firewall.us_vpn_dns.target='DNAT'
if uci -q get firewall.passwall >/dev/null; then uci set firewall.passwall.enabled='0'; uci -q delete firewall.passwall.reload || true; fi
uci commit firewall
fw4 check
uci set network."$WAN_IF".ipv6='0'
uci set network."$WAN_IF".peerdns='0'
if uci -q get network."$WAN6_IF" >/dev/null; then uci set network."$WAN6_IF".auto='0'; fi
uci -q delete network."$LAN_IF".ip6assign || true
uci -q delete network.globals.ula_prefix || true
uci commit network
uci set dhcp."$LAN_IF".ra='disabled'
uci set dhcp."$LAN_IF".dhcpv6='disabled'
uci set dhcp."$LAN_IF".ndp='disabled'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].allservers='0'
uci set dhcp.@dnsmasq[0].filter_aaaa='1'
uci set dhcp.@dnsmasq[0].cachesize='1000'
uci -q delete dhcp.@dnsmasq[0].server || true
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
if uci -q get dhcp.@dnsmasq[0].dns_redirect >/dev/null; then uci set dhcp.@dnsmasq[0].dns_redirect='0'; fi
uci commit dhcp
ifdown "$WAN6_IF" 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-us-vpn-ipv6.conf
if [ -x /etc/init.d/odhcpd ]; then /etc/init.d/odhcpd restart; fi
if [ -x /etc/init.d/miniupnpd ]; then /etc/init.d/miniupnpd stop; /etc/init.d/miniupnpd disable; fi
/etc/init.d/firewall restart
/etc/init.d/us-vpn enable
/etc/init.d/us-vpn start
/etc/init.d/dnsmasq restart
printf '\nApplied. Backup: %s\n' "$B"
printf 'After verification, within 10 minutes run:\ntouch "%s/confirmed"\n' "$B"
printf 'For immediate restoration: sh /root/us-vpn-rollback.sh\n'
```

### 17.10 `scripts/rollback-router.sh`

```sh
#!/bin/sh
# Restores only files/services changed by apply-router.sh; keep the backup.
set -u
[ -r /root/us-vpn-backup.current ] || { echo 'Missing backup pointer'; exit 1; }
B=$(cat /root/us-vpn-backup.current)
case "$B" in /root/us-vpn-backup-*) ;; *) echo 'Unexpected backup path'; exit 1;; esac
for f in network firewall dhcp; do
 [ -r "$B/$f" ] || { echo "Missing backup $f"; exit 1; }
done
if [ -x /etc/init.d/us-vpn ]; then /etc/init.d/us-vpn stop; /etc/init.d/us-vpn disable; fi
rm -f /etc/nftables.d/90-us-vpn-guard.nft /etc/sysctl.d/99-us-vpn-ipv6.conf
for f in network firewall dhcp; do cp -p "$B/$f" "/etc/config/$f"; done
if [ -r "$B/ipv6-state" ]; then
 while read -r path val; do
  case "$path" in /proc/sys/net/ipv6/conf/*/disable_ipv6) [ ! -w "$path" ] || printf '%s\n' "$val" > "$path";; esac
 done < "$B/ipv6-state"
fi
/etc/init.d/firewall restart
/etc/init.d/network reload
if [ -x /etc/init.d/odhcpd ]; then /etc/init.d/odhcpd restart; fi
/etc/init.d/dnsmasq restart
if [ -x /etc/init.d/miniupnpd ]; then
 [ ! -f "$B/upnp-enabled" ] || /etc/init.d/miniupnpd enable
 [ ! -f "$B/upnp-running" ] || /etc/init.d/miniupnpd start
fi
touch "$B/rolled-back"
echo "Restored pre-install networking from $B. VPN service remains disabled."
echo 'Original direct Internet and original IPv6 behavior may now be restored.'
```

### 17.11 `scripts/check-stun.py`

```python
import socket,struct,os,json,sys
expected=sys.argv[1] if len(sys.argv)>1 else None
for host,port in [('stun.l.google.com',19302),('stun.cloudflare.com',3478)]:
 s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(8)
 tx=os.urandom(12);packet=struct.pack('!HHI',1,0,0x2112a442)+tx
 try:
  addr=socket.getaddrinfo(host,port,socket.AF_INET,socket.SOCK_DGRAM)[0][4]
  s.sendto(packet,addr);d,_=s.recvfrom(2048)
  assert d[8:20]==tx
  p=20;ips=[]
  while p+4<=len(d):
   t,n=struct.unpack('!HH',d[p:p+4]);v=d[p+4:p+4+n];p+=4+((n+3)//4)*4
   if t in (1,32) and len(v)>=8 and v[1]==1:
    ip=struct.unpack('!I',v[4:8])[0]^(0x2112a442 if t==32 else 0)
    ips.append(socket.inet_ntoa(struct.pack('!I',ip)))
  print(json.dumps({'server':host,'public_ips':ips,'matches_expected':None if expected is None else bool(ips) and all(x==expected for x in ips)}))
 except Exception as e:print(json.dumps({'server':host,'error':str(e)}))
 finally:s.close()
```

以上为完整配套源码。复制到其他机器时保持 `scripts/`、`templates/` 的目录关系；实际执行顺序以第 4—11 节为准，不要按附录文件顺序逐个运行。
