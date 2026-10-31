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
