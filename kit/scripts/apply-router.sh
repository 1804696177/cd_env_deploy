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
