#!/usr/bin/env python3
"""fmtmodel.py: bit-exact reference of the VF attribute formats (ad_vf_fetch sizes, ad_vf_conv words).

Two paths, chosen per attribute:
  * legacy: ATTR_DESC[19:16] (see rtl/include/ad_vf_state.vh, AD_LF_*), used when ATTR_DST[31:24] == 0;
  * VkFormat: ATTR_DST[31:24] != 0 (CAPS[30]); the VkFormat enum value 1..255.

Conversions (all exact or correctly rounded, round to nearest even):
  * fp32 / uint32 / sint32 words pass through;
  * fp16 -> fp32 exactly (denormals become normal fp32, infinities kept, any NaN -> 0x7FC00000);
  * UNORMn: c / (2^n - 1) rounded to fp32;  SNORMn: max(c / (2^(n-1) - 1), -1.0) rounded to fp32;
  * UINTn zero-extended, SINTn sign-extended to 32 bits.
Missing components (format components < ATTR_DST count) fill (0, 0, 0, 1) where 1 is 1.0 (0x3F800000)
for float/norm kinds and integer 1 for UINT/SINT kinds.  A VkFormat without the vertex-buffer feature
(an entry not in VK below) reads (0, 0, 0, 1.0) with size 4.  An out-of-limit attribute (af_oob) writes
(0, 0, 0, 1) in the format's kind.

The VkFormat set (ASSUMED, see docs/ARCHITECTURE.md): 8-bit R, RG, RGBA and 16-/32-bit R, RG, RGB, RGBA in
UNORM, SNORM, UINT, SINT and (16/32-bit) SFLOAT; A8B8G8R8_*_PACK32 (same bytes as R8G8B8A8);
B8G8R8A8_UNORM; A2B10G10R10_UNORM_PACK32.  USCALED/SSCALED/SRGB and 3-byte RGB8 have no entry.
"""
import struct

ONE_F = 0x3F800000
NAN_F = 0x7FC00000

# kind codes (also used by the RTL: rtl/vf/fmt/ad_vf_fmt_info.v)
K_FLOAT, K_UNORM, K_SNORM, K_UINT, K_SINT = 0, 1, 2, 3, 4
KIND_NAMES = ['SFLOAT', 'UNORM', 'SNORM', 'UINT', 'SINT']

def _vk_table():
    t = {}
    def add(code, bits, ncomp, kind, swz=(0, 1, 2, 3), packed=None):
        t[code] = dict(bits=bits, ncomp=ncomp, kind=kind, swz=swz, packed=packed,
                       size=(4 if packed else bits * ncomp // 8))
    # 8-bit: R8 9..14, R8G8 16..21, R8G8B8A8 37..42 (UNORM, SNORM, USCALED, SSCALED, UINT, SINT)
    for base, n in ((9, 1), (16, 2), (37, 4)):
        add(base + 0, 8, n, K_UNORM); add(base + 1, 8, n, K_SNORM)
        add(base + 4, 8, n, K_UINT);  add(base + 5, 8, n, K_SINT)
    add(44, 8, 4, K_UNORM, swz=(2, 1, 0, 3))                 # B8G8R8A8_UNORM
    add(51, 8, 4, K_UNORM); add(52, 8, 4, K_SNORM)            # A8B8G8R8_*_PACK32
    add(55, 8, 4, K_UINT);  add(56, 8, 4, K_SINT)
    add(64, 10, 4, K_UNORM, packed=(10, 10, 10, 2))           # A2B10G10R10_UNORM_PACK32
    # 16-bit: R16 70.., R16G16 77.., R16G16B16 84.., R16G16B16A16 91.. (UNORM SNORM USC SSC UINT SINT SFLOAT)
    for base, n in ((70, 1), (77, 2), (84, 3), (91, 4)):
        add(base + 0, 16, n, K_UNORM); add(base + 1, 16, n, K_SNORM)
        add(base + 4, 16, n, K_UINT);  add(base + 5, 16, n, K_SINT); add(base + 6, 16, n, K_FLOAT)
    # 32-bit: R32 98.., R32G32 101.., R32G32B32 104.., R32G32B32A32 107.. (UINT SINT SFLOAT)
    for base, n in ((98, 1), (101, 2), (104, 3), (107, 4)):
        add(base + 0, 32, n, K_UINT); add(base + 1, 32, n, K_SINT); add(base + 2, 32, n, K_FLOAT)
    return t

VK = _vk_table()

# legacy formats: code -> (size, ncomp, kind, bits)
LEGACY = {0: (4, 1, K_FLOAT, 32), 1: (8, 2, K_FLOAT, 32), 2: (12, 3, K_FLOAT, 32), 3: (16, 4, K_FLOAT, 32),
          4: (4, 1, K_UINT, 32), 5: (8, 2, K_UINT, 32), 6: (4, 2, K_FLOAT, 16), 7: (8, 4, K_FLOAT, 16),
          8: (4, 4, K_UNORM, 8), 9: (4, 4, K_UINT, 8)}

def f2b(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]

def h2f(h):
    """fp16 -> fp32 bits, exact; NaN -> 0x7FC00000."""
    s, e, m = (h >> 15) & 1, (h >> 10) & 31, h & 0x3FF
    if e == 31:
        return NAN_F if m else (s << 31) | 0x7F800000
    if e == 0:
        if m == 0:
            return s << 31
        e = 1
        while not (m & 0x400):
            m <<= 1; e -= 1
        m &= 0x3FF
    return (s << 31) | ((e - 15 + 127) << 23) | (m << 13)

def norm_frac(c, n):
    """Correctly rounded (RNE) fp32 bits of c / (2^n - 1) for 0 <= c <= 2^n - 1."""
    d = (1 << n) - 1
    if c == 0:
        return 0
    if c == d:
        return ONE_F
    # exact rational rounding: find e with 2^23 <= c*2^k/d < 2^24
    k = 0
    while (c << k) < (d << 23):
        k += 1
    q, r = divmod(c << k, d)          # q in [2^23, 2^24)
    if 2 * r > d or (2 * r == d and (q & 1)):
        q += 1
    if q == 1 << 24:
        q >>= 1; k -= 1
    exp = 127 + 23 - k
    return (exp << 23) | (q & 0x7FFFFF)

def unorm(c, n):
    return norm_frac(c, n)

def snorm(c, n):
    """c is the n-bit two's complement field."""
    if c >> (n - 1):
        c -= 1 << n
    m = (1 << (n - 1)) - 1
    if c <= -m:
        return 0xBF800000
    if c < 0:
        return 0x80000000 | norm_frac(-c, n - 1)
    return norm_frac(c, n - 1)

def comp(kind, bits, c):
    if kind == K_FLOAT:
        return h2f(c) if bits == 16 else c
    if kind == K_UNORM:
        return unorm(c, bits)
    if kind == K_SNORM:
        return snorm(c, bits)
    if kind == K_UINT:
        return c
    # K_SINT
    if c >> (bits - 1):
        c -= 1 << bits
    return c & 0xFFFFFFFF

def one(kind):
    return 1 if kind in (K_UINT, K_SINT) else ONE_F

def info(vkfmt, legacy):
    """(size, ncomp, kind) of an attribute: vkfmt = ATTR_DST[31:24], legacy = ATTR_DESC[19:16]."""
    if vkfmt:
        e = VK.get(vkfmt)
        return (e['size'], e['ncomp'], e['kind']) if e else (4, 0, K_FLOAT)
    if legacy in LEGACY:
        s, n, k, _ = LEGACY[legacy]
        return (s, n, k)
    return (4, 0, K_FLOAT)

def convert(vkfmt, legacy, raw, oob=False):
    """4 words (x, y, z, w) of an attribute from raw bytes (bytes object, byte 0 = lowest address)."""
    raw = bytes(raw) + bytes(16)
    if vkfmt:
        e = VK.get(vkfmt)
        if e is None:
            return [0, 0, 0, ONE_F]
        kind = e['kind']
        if oob:
            return [0, 0, 0, one(kind)]
        if e['packed']:
            w = int.from_bytes(raw[0:4], 'little')
            f, sh = [], 0
            for b in e['packed']:
                f.append((w >> sh) & ((1 << b) - 1)); sh += b
            vals = [unorm(f[i], e['packed'][i]) for i in range(4)]
        else:
            nb = e['bits'] // 8
            fields = [int.from_bytes(raw[i * nb:(i + 1) * nb], 'little') for i in range(e['ncomp'])]
            vals = [comp(kind, e['bits'], fields[e['swz'][i]] if e['swz'][i] < e['ncomp'] else 0)
                    for i in range(e['ncomp'])]
        out = vals + [0, 0, 0, one(kind)][len(vals):]
        return out[:4]
    if legacy not in LEGACY:
        return [0, 0, 0, ONE_F]
    size, n, kind, bits = LEGACY[legacy]
    if oob:
        return [0, 0, 0, one(kind)]
    nb = bits // 8
    vals = [comp(kind, bits, int.from_bytes(raw[i * nb:(i + 1) * nb], 'little')) for i in range(n)]
    return (vals + [0, 0, 0, one(kind)][len(vals):])[:4]

def words(vkfmt, legacy, dst_cnt, raw, oob=False):
    """The register words ad_vf_conv writes: ATTR_DST count (dst_cnt + 1) of the 4."""
    return convert(vkfmt, legacy, raw, oob)[:dst_cnt + 1]

if __name__ == '__main__':
    assert unorm(255, 8) == ONE_F and unorm(128, 8) == f2b(128 / 255)
    for n in (2, 8, 10, 16):
        for c in range(0, 1 << n, max(1, (1 << n) // 4096)):
            assert unorm(c, n) == f2b(c / ((1 << n) - 1)), (n, c)
    for c in range(256):
        v = c - 256 if c > 127 else c
        assert snorm(c, 8) == f2b(max(v / 127, -1.0)), c
    assert h2f(0x3C00) == ONE_F and h2f(0x0001) == f2b(2 ** -24) and h2f(0x7E01) == NAN_F
    print('fmtmodel self-test PASS (%d VkFormats)' % len(VK))
