#!/usr/bin/env python3
"""Generate the Ruckus icon as a PNG, with no image-library dependency.

A speaker cone throwing three arcs, on the teal accent. Written by hand
because ImageMagick and PIL are not guaranteed to be present, and a build
should not depend on either.
"""
import struct, zlib, sys, os

SIZE = 256
BG = (14, 18, 20, 255)        # ground
FG = (79, 203, 212, 255)      # accent
DIM = (16, 49, 47, 255)       # accent-soft

def blank():
    return [[BG for _ in range(SIZE)] for _ in range(SIZE)]

def put(px, x, y, c):
    if 0 <= x < SIZE and 0 <= y < SIZE:
        px[y][x] = c

def disc(px, cx, cy, r, c):
    for y in range(cy - r, cy + r + 1):
        for x in range(cx - r, cx + r + 1):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                put(px, x, y, c)

def arc(px, cx, cy, r, thickness, c, half_span_deg=55):
    import math
    for t in range(0, 3600):
        a = math.radians(t / 10.0)
        deg = (t / 10.0 + 360) % 360
        if not (deg < half_span_deg or deg > 360 - half_span_deg):
            continue
        for w in range(thickness):
            x = int(cx + (r + w) * math.cos(a))
            y = int(cy + (r + w) * math.sin(a))
            put(px, x, y, c)

def main(out):
    px = blank()
    cx, cy = 96, 128

    # rounded backing plate
    disc(px, 128, 128, 118, DIM)

    # speaker body: a box plus a trapezoid cone
    for y in range(cy - 26, cy + 27):
        for x in range(cx - 46, cx - 16):
            put(px, x, y, FG)
    for i in range(52):
        halfh = 26 + i
        x = cx - 16 + i
        for y in range(cy - halfh, cy + halfh + 1):
            put(px, x, y, FG)

    # three sound arcs
    for i, r in enumerate((26, 46, 66)):
        arc(px, cx + 44, cy, r, 7, FG)

    raw = b''
    for y in range(SIZE):
        raw += b'\x00' + b''.join(struct.pack('BBBB', *px[y][x]) for x in range(SIZE))

    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9))
    png += chunk(b'IEND', b'')

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'wb') as f:
        f.write(png)
    print(f'wrote {out} ({len(png)} bytes)')

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'packaging/ruckus.png')
