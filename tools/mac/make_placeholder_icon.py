#!/usr/bin/env python3
"""Placeholder 1024x1024 iOS app icon for the Godot export (native/platform/ios/icon_1024.png).

가설: ❓ 아이콘이 비어 있으면 Godot 4.7.2 iOS export가 "Invalid icon (icons/settings_58x58)"로 실패한다
(컨테이너 재현 ✅). 불투명 1024 아이콘 1장만 preset의 icons/icon_1024x1024에 주면 나머지 크기는 Godot가 만든다.

Top-down highway jam: four lanes, a queue of tail-lit cars, and the player's car pushing up lane 1.
Deterministic (no RNG); needs Pillow. Usage: python3 tools/mac/make_placeholder_icon.py [out.png]
"""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "native/platform/ios/icon_1024.png"


def car(d: ImageDraw.ImageDraw, cx: int, cy: int, w: int, h: int, body: tuple[int, int, int], tail: bool) -> None:
    x0, y0, x1, y1 = cx - w // 2, cy - h // 2, cx + w // 2, cy + h // 2
    d.rounded_rectangle((x0 + 6, y0 + 10, x1 + 6, y1 + 10), radius=18, fill=(10, 12, 18))  # drop shadow
    d.rounded_rectangle((x0, y0, x1, y1), radius=18, fill=body)
    roof = tuple(max(0, c - 40) for c in body)
    d.rounded_rectangle((x0 + 14, y0 + h * 0.28, x1 - 14, y1 - h * 0.22), radius=12, fill=roof)
    glass = (150, 190, 220)
    d.rounded_rectangle((x0 + 18, y0 + h * 0.18, x1 - 18, y0 + h * 0.30), radius=6, fill=glass)
    if tail:
        d.rectangle((x0 + 8, y1 - 16, x0 + 30, y1 - 6), fill=(255, 60, 50))
        d.rectangle((x1 - 30, y1 - 16, x1 - 8, y1 - 6), fill=(255, 60, 50))


def main() -> None:
    img = Image.new("RGB", (SIZE, SIZE), (24, 28, 38))
    d = ImageDraw.Draw(img)
    # Sky-to-asphalt vertical gradient behind the road.
    for y in range(SIZE):
        t = y / SIZE
        d.line((0, y, SIZE, y), fill=(int(40 + 20 * t), int(52 + 10 * t), int(70 - 10 * t)))
    road_l, road_r = 120, 904
    d.rectangle((road_l, 0, road_r, SIZE), fill=(52, 56, 64))
    d.rectangle((road_l - 18, 0, road_l, SIZE), fill=(230, 190, 40))  # median edge line (yellow)
    d.rectangle((road_r, 0, road_r + 10, SIZE), fill=(235, 235, 235))
    lane_w = (road_r - road_l) // 4
    for i in range(1, 4):
        x = road_l + i * lane_w
        for y in range(-40, SIZE, 130):
            d.rectangle((x - 6, y, x + 6, y + 70), fill=(235, 235, 235))

    # Glow of brake lights ("빨간 바다") under the cars.
    glow = Image.new("RGB", (SIZE, SIZE), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for lane in range(4):
        cx = road_l + lane * lane_w + lane_w // 2
        for row in range(4):
            cy = 120 + row * 210 + (lane * 37) % 60
            gd.ellipse((cx - 90, cy + 40, cx + 90, cy + 150), fill=(150, 20, 15))
    glow = glow.filter(ImageFilter.GaussianBlur(40))
    img = ImageChops.add(img, glow)
    d = ImageDraw.Draw(img)

    palette = [(70, 90, 160), (200, 200, 205), (40, 40, 48), (120, 130, 140), (180, 70, 60), (90, 120, 90)]
    k = 0
    for lane in range(4):
        cx = road_l + lane * lane_w + lane_w // 2
        for row in range(4):
            if lane == 0 and row == 3:
                continue  # leave room for the player in lane 1
            cy = 120 + row * 210 + (lane * 37) % 60
            car(d, cx, cy, lane_w - 70, 170, palette[k % len(palette)], tail=True)
            k += 1
    # Player car: bright, in lane 1 at the bottom, with headlight beams.
    pcx = road_l + lane_w // 2
    beam = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(beam).polygon([(pcx - 50, 800), (pcx + 50, 800), (pcx + 140, 560), (pcx - 140, 560)], fill=110)
    beam = beam.filter(ImageFilter.GaussianBlur(18))
    img = Image.composite(Image.new("RGB", (SIZE, SIZE), (255, 240, 170)), img, beam)
    d = ImageDraw.Draw(img)
    car(d, pcx, 880, lane_w - 60, 190, (250, 200, 30), tail=False)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT, "PNG", optimize=True)
    print(f"wrote {OUT} {img.size} mode={img.mode}")


if __name__ == "__main__":
    main()
