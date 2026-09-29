#!/usr/bin/env python3
"""Compare two MaterialIcons font files and report glyphs only in the new one.

Shorebird refuses to patch when the icon font changes, because the font is an
asset and assets are NOT shipped in a code patch. So a newly reachable screen
introducing an unseen IconData glyph blocks every patch until it is either
mapped to a glyph already in the shipped font, or shipped in a new release.

Usage: icon_font_diff.py <baseline.otf> <new.otf>
"""
import struct
import sys


def cmap_codepoints(path):
    data = open(path, 'rb').read()
    num_tables = struct.unpack('>H', data[4:6])[0]

    cmap_off = None
    for i in range(num_tables):
        rec = 12 + i * 16
        if data[rec:rec + 4] == b'cmap':
            cmap_off = struct.unpack('>I', data[rec + 8:rec + 12])[0]
    if cmap_off is None:
        return set()

    num_sub = struct.unpack('>H', data[cmap_off + 2:cmap_off + 4])[0]
    points = set()
    for i in range(num_sub):
        rec = cmap_off + 4 + i * 8
        # The subtable offset is relative to the start of the cmap table.
        sub = cmap_off + struct.unpack('>I', data[rec + 4:rec + 8])[0]
        fmt = struct.unpack('>H', data[sub:sub + 2])[0]
        if fmt != 4:
            continue
        seg_x2 = struct.unpack('>H', data[sub + 6:sub + 8])[0]
        seg = seg_x2 // 2
        end_base = sub + 14
        ends = [
            struct.unpack('>H', data[end_base + 2 * j:end_base + 2 + 2 * j])[0]
            for j in range(seg)
        ]
        start_base = sub + 16 + seg_x2
        starts = [
            struct.unpack('>H', data[start_base + 2 * j:start_base + 2 + 2 * j])[0]
            for j in range(seg)
        ]
        for s, e in zip(starts, ends):
            if s == 0xFFFF:
                continue
            points.update(range(s, e + 1))
    return points


baseline, new = sys.argv[1], sys.argv[2]
a = cmap_codepoints(baseline)
b = cmap_codepoints(new)
print('baseline glyphs:', len(a))
print('new glyphs:     ', len(b))
added = sorted(b - a)
print('ADDED (%d): %s' % (len(added), added))
print('REMOVED (%d): %s' % (len(sorted(a - b)), sorted(a - b)))
