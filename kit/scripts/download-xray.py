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
