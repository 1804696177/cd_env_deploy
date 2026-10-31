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
