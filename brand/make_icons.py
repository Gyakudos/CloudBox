#!/usr/bin/env python3
"""Generate the CloudBox app icon with the Python standard library only.

No Pillow / image dependencies: pixels are rasterized directly into RGBA bytes, compressed with
``zlib`` and wrapped in PNG chunks (and in an ICO directory for Windows). Edges are antialiased
by supersampling each output pixel and averaging the subpixel coverage.

Outputs (relative to the repository root):
  brand/cloudbox-icon.png                               512 x 512 master
  app/android/app/src/main/res/mipmap-*/ic_launcher.png Android launcher densities
  pc/windows/runner/resources/app_icon.ico              16/32/48/64/128/256 PNG entries
"""

from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

BLUE_TOP = (59, 130, 246)
BLUE_BOTTOM = (29, 78, 216)
WHITE = (255, 255, 255)

ANDROID_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}
ICO_SIZES = (16, 32, 48, 64, 128, 256)


def rounded_box(x: float, y: float, cx: float, cy: float,
                half_w: float, half_h: float, radius: float) -> float:
    """Signed distance to an axis-aligned rounded rectangle (negative = inside)."""
    dx = abs(x - cx) - (half_w - radius)
    dy = abs(y - cy) - (half_h - radius)
    return math.hypot(max(dx, 0.0), max(dy, 0.0)) + min(max(dx, dy), 0.0) - radius


def in_cloud(x: float, y: float) -> bool:
    """Three bumps and a flat base make a simple, recognizable cloud."""
    if (x + 0.30) ** 2 + (y - 0.30) ** 2 <= 0.17 ** 2:
        return True
    if x * x + (y - 0.40) ** 2 <= 0.22 ** 2:
        return True
    if (x - 0.30) ** 2 + (y - 0.30) ** 2 <= 0.17 ** 2:
        return True
    return rounded_box(x, y, 0.0, 0.28, 0.40, 0.14, 0.13) <= 0.0


def in_arrow(x: float, y: float) -> bool:
    """Down arrow connecting the cloud to the box/tray."""
    if rounded_box(x, y, 0.0, 0.00, 0.085, 0.20, 0.05) <= 0.0:
        return True
    if -0.44 <= y <= -0.12:
        half_width = 0.24 * (y + 0.44) / 0.32
        return abs(x) <= half_width
    return False


def in_box(x: float, y: float) -> bool:
    """Open-topped box: two walls and a bottom, so the arrow visibly drops into it."""
    if rounded_box(x, y, -0.37, -0.50, 0.075, 0.15, 0.04) <= 0.0:
        return True
    if rounded_box(x, y, 0.37, -0.50, 0.075, 0.15, 0.04) <= 0.0:
        return True
    return rounded_box(x, y, 0.0, -0.62, 0.445, 0.07, 0.04) <= 0.0


def render_rgba(size: int, supersample: int = 4) -> bytes:
    """Render the icon at ``size`` pixels, using sxS subpixel coverage for antialiasing."""
    rgba = bytearray(size * size * 4)
    samples = supersample * supersample
    half = size / 2.0
    scale = 2.0 / size

    for py in range(size):
        for px in range(size):
            background_hits = 0
            glyph_hits = 0
            shade = ((px + 0.5) / size + (1.0 - (py + 0.5) / size)) / 2.0
            shade = min(1.0, max(0.0, shade))

            for sy in range(supersample):
                y = (half - (py + (sy + 0.5) / supersample)) * scale
                for sx in range(supersample):
                    x = ((px + (sx + 0.5) / supersample) - half) * scale
                    if rounded_box(x, y, 0.0, 0.0, 1.0, 1.0, 0.22) <= 0.0:
                        background_hits += 1
                        if in_cloud(x, y) or in_arrow(x, y) or in_box(x, y):
                            glyph_hits += 1

            offset = (py * size + px) * 4
            alpha = round(255.0 * background_hits / samples)
            if alpha == 0:
                continue

            glyph = glyph_hits / samples
            for channel in range(3):
                background = round(
                    BLUE_TOP[channel] * (1.0 - shade) + BLUE_BOTTOM[channel] * shade
                )
                rgba[offset + channel] = round(
                    background * (1.0 - glyph) + WHITE[channel] * glyph
                )
            rgba[offset + 3] = alpha

    return bytes(rgba)


def png_chunk(tag: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def encode_png(size: int, rgba: bytes) -> bytes:
    stride = size * 4
    raw = bytearray()
    for row in range(size):
        raw.append(0)  # PNG filter type: None
        raw.extend(rgba[row * stride:(row + 1) * stride])

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (
        PNG_SIGNATURE
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + png_chunk(b"IEND", b"")
    )


def encode_ico(images: list[tuple[int, bytes]]) -> bytes:
    """Build a multi-resolution ICO using PNG-compressed entries (supported on Windows Vista+)."""
    count = len(images)
    header = bytearray(struct.pack("<HHH", 0, 1, count))
    directory = bytearray()
    payload = bytearray()
    offset = 6 + 16 * count

    for size, png in images:
        # ICO stores 256 as a zero byte; bit depth 32 for RGBA.
        directory.extend(
            struct.pack(
                "<BBBBHHII",
                size if size < 256 else 0,
                size if size < 256 else 0,
                0,
                0,
                1,
                32,
                len(png),
                offset,
            )
        )
        payload.extend(png)
        offset += len(png)

    return bytes(header) + bytes(directory) + bytes(payload)


def write_file(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def read_png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        raise ValueError(f"{path}: not a PNG file")
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def verify() -> None:
    """Reopen every generated file and assert its format, dimensions and non-empty payload."""
    expected: list[tuple[Path, int]] = [(ROOT / "brand/cloudbox-icon.png", 512)]
    expected.extend(
        (
            ROOT / f"app/android/app/src/main/res/mipmap-{density}/ic_launcher.png",
            size,
        )
        for density, size in ANDROID_SIZES.items()
    )
    for path, size in expected:
        if path.stat().st_size == 0:
            raise ValueError(f"{path}: empty file")
        if read_png_size(path) != (size, size):
            raise ValueError(f"{path}: expected {size}x{size}")

    ico_path = ROOT / "pc/windows/runner/resources/app_icon.ico"
    data = ico_path.read_bytes()
    if len(data) == 0:
        raise ValueError(f"{ico_path}: empty file")
    reserved, kind, count = struct.unpack("<HHH", data[:6])
    if (reserved, kind, count) != (0, 1, len(ICO_SIZES)):
        raise ValueError(f"{ico_path}: invalid ICO header")

    found: list[int] = []
    for index in range(count):
        entry = data[6 + 16 * index:22 + 16 * index]
        width, height, _, _, planes, depth, byte_count, image_offset = struct.unpack(
            "<BBBBHHII", entry
        )
        actual = (width or 256, height or 256)
        png = data[image_offset:image_offset + byte_count]
        if png[:8] != PNG_SIGNATURE:
            raise ValueError(f"{ico_path}: entry {index} is not PNG-compressed")
        if read_png_entry_size(png) != actual or planes != 1 or depth != 32:
            raise ValueError(f"{ico_path}: invalid entry {index}")
        found.append(actual[0])

    if tuple(found) != ICO_SIZES:
        raise ValueError(f"{ico_path}: expected sizes {ICO_SIZES}, got {tuple(found)}")

    print(f"Verified master PNG: 512x512")
    for density, size in ANDROID_SIZES.items():
        print(f"Verified {density}/ic_launcher.png: {size}x{size}")
    print(f"Verified app_icon.ico: {', '.join(str(s) for s in found)} px")


def read_png_entry_size(png: bytes) -> tuple[int, int]:
    if png[12:16] != b"IHDR":
        raise ValueError("PNG entry has no IHDR")
    return struct.unpack(">II", png[16:24])


def main() -> None:
    master = encode_png(512, render_rgba(512, supersample=4))
    write_file(ROOT / "brand/cloudbox-icon.png", master)

    for density, size in ANDROID_SIZES.items():
        # Smaller icons get more subpixel samples so the arrow and box stay legible.
        samples = 6 if size < 96 else 4
        write_file(
            ROOT / f"app/android/app/src/main/res/mipmap-{density}/ic_launcher.png",
            encode_png(size, render_rgba(size, supersample=samples)),
        )

    ico_images = []
    for size in ICO_SIZES:
        samples = 8 if size <= 32 else 6 if size < 128 else 4
        ico_images.append((size, encode_png(size, render_rgba(size, supersample=samples))))
    write_file(ROOT / "pc/windows/runner/resources/app_icon.ico", encode_ico(ico_images))

    verify()


if __name__ == "__main__":
    main()
