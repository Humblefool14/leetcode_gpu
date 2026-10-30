import random, sys
r = random.Random(3)
T = []
for i in range(300):
    if i < 20:   # shared-edge pairs and screen-edge cases
        a, b, c, d = (r.randint(-10, 70), r.randint(-10, 55), r.randint(-10, 70), r.randint(-10, 55))
        e, f = r.randint(-10, 70), r.randint(-10, 55)
        T.append((a, b, c, d, e, f)); T.append((c, d, a, b, r.randint(-10, 70), r.randint(-10, 55)))
    else:
        T.append(tuple(r.randint(-8, 72) if k % 2 == 0 else r.randint(-8, 56) for k in range(6)))
if sys.argv[1] == 'gen':
    open('rc_in.txt', 'w').write(''.join(' '.join(map(str, t)) + '\n' for t in T)); sys.exit()
def cover(t):
    x0, y0, x1, y1, x2, y2 = t
    D = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    if D == 0: return set()
    P = [(x0, y0), (x1, y1), (x2, y2)] if D > 0 else [(x0, y0), (x2, y2), (x1, y1)]
    out = set()
    for py in range(max(0, min(y0, y1, y2)), min(47, max(y0, y1, y2)) + 1):
        for px in range(max(0, min(x0, x1, x2)), min(63, max(x0, x1, x2)) + 1):
            ok = True
            for i in range(3):
                (ax, ay), (bx, by) = P[i], P[(i + 1) % 3]
                A, B = -(by - ay), bx - ax
                E = A * (2 * px + 1 - 2 * ax) + B * (2 * py + 1 - 2 * ay)
                tl = A > 0 or (A == 0 and B > 0)
                if not (E > 0 or (E == 0 and tl)): ok = False
            if ok: out.add((px, py))
    return out
got = []
for l in open('rc_out.txt'):
    if l[0] == 'T': got.append([])
    else: got[-1].append(tuple(map(int, l.split()[1:])))
bad = sum(1 for t, g in zip(T, got) if sorted(g) != sorted(cover(t)) or len(g) != len(set(g)))
print(("PASS" if bad == 0 and len(got) == len(T) else "FAIL") + f" rasterizer_core: {len(T)} triangles, {sum(map(len, got))} fragments, {bad} mismatching")
