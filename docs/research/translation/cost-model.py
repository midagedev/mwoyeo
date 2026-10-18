N=200;NEW=75;OUT=75;P=1000;TURN=NEW+OUT
M={ # in, cached read, write mult over in, out  ($/M)
 'gpt-5.4-nano':(0.20,0.02,1.0,1.25),
 'gpt-6-luna':(0.10,0.01,1.25,0.50),
 'haiku-5.5':(0.10,0.01,1.25,0.50),
 'gem-3.1-flash-lite*':(0.25,0.025,1.0,1.50)}
def run(C,mode,idle=0):
    # returns (uncached_in, read, write) tokens summed over session
    T=0;u=r=w=0;ctx_prev=None
    for n in range(N):
        if mode=='stateless':
            u+=P+NEW;continue
        if mode=='today': u+=100+NEW;continue
        ctx=P+T
        if mode=='nocache': u+=ctx+NEW
        else:
            if mode=='slide' : hit = ctx_prev is not None and T<C   # window slid => prefix changed
            else: hit = ctx_prev is not None
            if n in IDLE: hit=False
            if hit: r+=ctx_prev; w+=ctx-ctx_prev; u+=NEW
            else: w+=ctx; u+=NEW
        ctx_prev=ctx+TURN if True else 0
        ctx_prev=P+min(T+TURN,10**9)
        T+=TURN
        if T>C:
            T=C if mode=='slide' else C//2   # slide: drop oldest each turn (prefix changes); compact: reset to half once
            if mode=='slide': ctx_prev=None
            else: ctx_prev=None  # compaction rewrites prefix: one miss
    return u,r,w
IDLE=set()
def cost(m,u,r,w):
    i,c,wm,o=M[m];return (u*i+r*c+w*i*wm+N*OUT*o)/1e6
for C in(2000,8000,32000):
  print('C=',C)
  for mode in('today','stateless','nocache','slide','compact'):
    IDLE=set() 
    row=[]
    for m in M:
        u,r,w=run(C,mode); row.append(f"{m}:{cost(m,u,r,w)*100:.3f}c")
    print(' ',mode,' '.join(row), 'tok(u/r/w)',run(C,mode))
  IDLE={60,140}
  row=[f"{m}:{cost(m,*run(C,'compact'))*100:.3f}c" for m in M]
  print('  compact+2idle>5min',' '.join(row))
