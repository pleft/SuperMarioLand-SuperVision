# python3 tools/svcut.py in.txt FRAMES > out : the first FRAMES frames of a pad script
import sys
seq=[]
for seg in open(sys.argv[1]).read().strip().split(','): seq+=[seg[0]]*int(seg[1:])
seq=seq[:int(sys.argv[2])]; out=[]; i=0
while i<len(seq):
    j=i
    while j<len(seq) and seq[j]==seq[i]: j+=1
    out.append(f"{seq[i]}{j-i}"); i=j
print(','.join(out))
