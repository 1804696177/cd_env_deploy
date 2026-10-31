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
