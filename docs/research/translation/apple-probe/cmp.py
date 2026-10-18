import sys,re
t=open(sys.argv[1]).read().split('\n#')
n=same=nil=0;diffs=[]
for blk in t:
    L=blk.strip().split('\n')
    if len(L)<4: continue
    A=L[1].split(None,2)[2] if len(L[1].split(None,2))>2 else ''
    m=re.search(r'ext=(.*?)  full=(.*)',L[2]); c=re.search(r'ext=(.*?)  full=(.*)',L[3])
    n+=1
    for name,x in (('B',m),('C',c)):
        pass
    B=m.group(1); C=c.group(1)
    if B=='NIL': nil+=1
    if B==A: same+=1
    else: diffs.append((L[0],A,B,C))
print('n',n,'B==A',same,'B NIL',nil)
for d in diffs: print(d)
