import struct
with open('.zig-cache/_ghostty.spv','rb') as f: data = f.read()
nw = len(data)//4
w = struct.unpack('<'+('I'*nw), data)
print(f"Total words: {nw}, bound: {w[3]}")

# Find all definitions of result_id = 273
pos = 5
defs = []
while pos < nw:
    hdr = w[pos]; wc = hdr >> 16; op = hdr & 0xFFFF
    if wc == 0 or pos+wc > nw: break
    if wc >= 3 and w[pos+2] == 273:
        defs.append((pos, op, wc))
    pos += wc

print(f"\nDefinitions of ID 273: {len(defs)}")
for p, op, wc in defs:
    ops = [str(w[p+i]) for i in range(wc)]
    print(f"  pos={p} op={op} wc={wc}: {' '.join(ops)}")

# Show context - scan from a fixed point near each definition
for target_p, _, _ in defs:
    print(f"\nContext around pos {target_p}:")
    # Walk instructions from pos 5 to find the one just before and after
    pp = 5
    prev_instrs = []
    while pp < nw:
        hdr2 = w[pp]; wc2 = hdr2 >> 16; op2 = hdr2 & 0xFFFF
        if wc2 == 0 or pp+wc2 > nw: break
        ops2 = [str(w[pp+i]) for i in range(min(wc2, 8))]
        marker = " <-- DUP" if pp == target_p else ""
        if abs(pp - target_p) < 30:
            print(f"  [{pp}] op={op2} wc={wc2}: {' '.join(ops2)}{marker}")
        pp += wc2
