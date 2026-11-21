from PIL import Image, ImageDraw, ImageFilter
import math
K=4; N=1024*K
s=824/236*K
def P(x,y): return (100*K+(x-10)*s, 100*K+(y-8)*s)
def L(v): return v*s
img=Image.new('RGBA',(N,N),(0,0,0,0))
d=ImageDraw.Draw(img)
x0,y0=P(10,8); x1,y1=P(246,250)
# body: square 824, y range mapped to make square
x0,y0,x1,y1=100*K,100*K,924*K,924*K
d.rounded_rectangle([x0,y0,x1,y1],radius=185*K,fill=(20,22,28,255))
cx,cy=P(128,124)
# eye arcs
bx=[cx-L(92),cy-L(47),cx+L(92),cy+L(47)]
w=int(L(6))
d.arc(bx,200,338,fill=(235,240,248,255),width=w)
d.arc(bx,20,157,fill=(235,240,248,255),width=w)
# rays
ic=P(122,124)
for i in range(28):
    a=2*math.pi*i/28
    r0,r1=L(17),L(42)
    d.line([ic[0]+r0*math.cos(a),ic[1]+r0*math.sin(a),ic[0]+r1*math.cos(a),ic[1]+r1*math.sin(a)],fill=(235,240,248,235),width=int(L(2)))
# ring
r=L(14); d.ellipse([ic[0]-r,ic[1]-r,ic[0]+r,ic[1]+r],fill=(8,10,14,255),outline=(235,240,248,255),width=int(L(2.2)))
r=L(3.2); d.ellipse([ic[0]-r,ic[1]-r,ic[0]+r,ic[1]+r],fill=(235,240,248,255))
# red dot with halo
rc=P(50,126)
halo=Image.new('RGBA',(N,N),(0,0,0,0)); hd=ImageDraw.Draw(halo)
r=L(19); hd.ellipse([rc[0]-r,rc[1]-r,rc[0]+r,rc[1]+r],fill=(255,208,208,235))
img=Image.alpha_composite(img,halo); d=ImageDraw.Draw(img)
r=L(10); d.ellipse([rc[0]-r,rc[1]-r,rc[0]+r,rc[1]+r],fill=(255,80,80,255))
out=img.resize((1024,1024),Image.LANCZOS)
out.save('icon-1024.png'); out.resize((512,512),Image.LANCZOS).save('icon-512.png')
out.resize((128,128),Image.LANCZOS).save('icon-128.png')
