#!/usr/bin/env python3
"""discriminate.py — compare candidate render PNG vs known-blank refs.
Metrics: mean abs diff, % pixels differing >12 gray levels, non-white ratio.
Exit 0 + DISTINCT iff candidate differs from EVERY blank ref beyond thresholds.
Usage: discriminate.py <candidate.png> <blank1.png> [blank2.png ...]
"""
import subprocess, sys, os

def gray_pixels(png):
    # sips -> raw? Use python zlib PNG decode for RGBA8.
    import zlib, struct
    d = open(png, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', f'not png: {png}'
    pos, w, h, ctype, idat = 8, 0, 0, 0, b''
    while pos < len(d):
        (ln,) = struct.unpack('>I', d[pos:pos+4]); typ = d[pos+4:pos+8]
        if typ == b'IHDR':
            w, h, bd, ctype = struct.unpack('>IIBB', d[pos+8:pos+18])
        elif typ == b'IDAT':
            idat += d[pos+8:pos+8+ln]
        pos += 12 + ln
    assert ctype in (2, 6), f'need RGB/RGBA, got {ctype} in {png}'
    ch = 3 if ctype == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * ch
    px = bytearray(w * h)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        if f == 1:
            for i in range(ch, stride): line[i] = (line[i] + line[i-ch]) & 255
        elif f == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i-ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i-ch] if i >= ch else 0
                b = prev[i]
                c = prev[i-ch] if i >= ch else 0
                pp = a + b - c
                pa, pb, pc = abs(pp-a), abs(pp-b), abs(pp-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        elif f != 0:
            raise ValueError(f'filter {f}')
        for x in range(w):
            r, g, b = line[x*ch], line[x*ch+1], line[x*ch+2]
            px[y*w+x] = (r*77 + g*150 + b*29) >> 8
        prev = line
    return w, h, px

def median(px):
    s = sorted(px)
    return s[len(s)//2]

def stats(a, b):
    assert len(a) == len(b), 'size mismatch'
    n = len(a)
    # bg-normalized: blank shells differ by global shade (alert dimming,
    # light/dark), content differs structurally. Subtract medians first.
    ma, mb = median(a), median(b)
    mad_raw = sum(abs(a[i]-b[i]) for i in range(n)) / n
    diff = sum(1 for i in range(n) if abs((a[i]-ma)-(b[i]-mb)) > 12)
    mad = sum(abs((a[i]-ma)-(b[i]-mb)) for i in range(n)) / n
    return mad, 100.0*diff/n, mad_raw

def nonwhite(px):
    n = len(px)
    return 100.0*sum(1 for v in px if v < 235)/n

cand = sys.argv[1]
blanks = sys.argv[2:]
assert len(blanks) >= 1
cw, chh, cpx = gray_pixels(cand)
print(f'candidate {cand} {cw}x{chh} nonwhite={nonwhite(cpx):.2f}%')
distinct_all = True
for b in blanks:
    bw, bh, bpx = gray_pixels(b)
    if (bw, bh) != (cw, chh):
        print(f'  vs {os.path.basename(b)}: SIZE-DIFFERS ({bw}x{bh}) -> distinct')
        continue
    mad, pct, raw = stats(cpx, bpx)
    distinct = mad > 3.0 and pct > 2.0
    distinct_all &= distinct
    print(f'  vs {os.path.basename(b)}: nMAD={mad:.2f} ndiffpct={pct:.2f}% rawMAD={raw:.2f} -> {"DISTINCT" if distinct else "SAME-AS-BLANK"}')
print('VERDICT:', 'DISTINCT-RENDER' if distinct_all else 'BLANK-SHELL')
sys.exit(0 if distinct_all else 1)
