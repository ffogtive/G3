#!/usr/bin/env python3
"""Merge @fontsource unicode-range subsets (woff2) into one TTF per family for Godot (NATIVE_PORT 3-8).

가설: fontsource ships Korean as ~120 numbered woff2 slices of the same font; fontTools.merge can stitch them back into
      one font, and subsetting to KS X 1001 (2350 syllables) + ASCII + every character used in native/data keeps
      the file small while covering all game text.

usage: python3 merge_fonts.py <fontsource package dir> <out.ttf> <native/data dir>
needs: fonttools, brotli (pip). Writes <out.ttf>; prints glyph count and cmap coverage.
"""
import glob
import json
import os
import sys
import tempfile

from fontTools import subset
from fontTools.merge import Merger
from fontTools.ttLib import TTFont


def ks_x_1001_hangul():
    out = []
    for hi in range(0xB0, 0xC9):
        for lo in range(0xA1, 0xFF):
            try:
                out.append(bytes([hi, lo]).decode("euc-kr"))
            except UnicodeDecodeError:
                pass
    return out


def data_chars(data_dir):
    chars = set()

    def walk(v):
        if isinstance(v, str):
            chars.update(v)
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif isinstance(v, dict):
            for k, x in v.items():
                walk(k)
                walk(x)

    for p in sorted(glob.glob(os.path.join(data_dir, "*.json"))):
        with open(p, encoding="utf-8") as f:
            walk(json.load(f))
    return chars


def main():
    pkg, out, data_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    files = sorted(glob.glob(os.path.join(pkg, "files", "*-400-normal.woff2")))
    if not files:
        sys.exit("no woff2 files in " + pkg)
    tmp = tempfile.mkdtemp()
    ttfs = []
    for i, p in enumerate(files):
        f = TTFont(p)
        f.flavor = None
        q = os.path.join(tmp, "%03d.ttf" % i)
        f.save(q)
        ttfs.append(q)
    merged = Merger().merge(ttfs)
    mpath = os.path.join(tmp, "merged.ttf")
    merged.save(mpath)

    want = set(chr(c) for c in range(0x20, 0x7F)) | set(ks_x_1001_hangul()) | data_chars(data_dir)
    want |= set("·…‘’“”•○●◀▶▲▼★☆♥×→←↑↓—–「」『』《》%℃㎞㎧")
    font = TTFont(mpath)
    cmap = font.getBestCmap()
    have = {ch for ch in want if ord(ch) in cmap}
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    sub = subset.Subsetter(opts)
    sub.populate(unicodes=[ord(c) for c in have])
    sub.subset(font)
    font.save(out)
    hangul = [c for c in ks_x_1001_hangul()]
    cm2 = TTFont(out).getBestCmap()
    miss_ks = [c for c in hangul if ord(c) not in cm2]
    miss_data = sorted(c for c in data_chars(data_dir) if ord(c) not in cm2 and not c.isspace())
    print("%s: slices=%d glyphs=%d cmap=%d ks_x_1001_missing=%d data_missing=%d %s bytes=%d" % (
        os.path.basename(out), len(files), len(TTFont(out).getGlyphOrder()), len(cm2), len(miss_ks), len(miss_data),
        "".join(miss_data[:40]), os.path.getsize(out)))


if __name__ == "__main__":
    main()
