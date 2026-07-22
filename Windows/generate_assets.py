"""生成 KimiCodeBar 占位图标资源（蓝色方块）。
仅用于让清单引用有效；用户应替换为正式图标。
"""
import struct
import zlib
import os

OUT_DIR = os.path.join(os.path.dirname(__file__), "src", "KimiCodeBar", "Assets")
os.makedirs(OUT_DIR, exist_ok=True)

KIMI_BLUE = (0x3B, 0x82, 0xF5, 0xFF)  # #FF3B82F5 (RGBA)


def make_png(path, size):
    w = h = size
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0
        for x in range(w):
            raw += bytes(KIMI_BLUE)
    compressed = zlib.compress(bytes(raw), 9)

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", compressed)
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def make_ico(path, size):
    """写入单图像 ICO（BGRA 未压缩，无 PNG 压缩以最大兼容）。"""
    w = h = size
    # BITMAPINFOHEADER
    bmp_header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, w * h * 4, 0, 0, 0, 0)
    pixels = bytearray()
    for y in range(h - 1, -1, -1):
        for x in range(w):
            r, g, b, a = KIMI_BLUE
            pixels += bytes((b, g, r, a))  # BGRA
    # ICONDIRENTRY
    dir_entry = struct.pack("<BBBBHHII",
                             w & 0xFF, h & 0xFF, 0, 0, 1, 32,
                             len(bmp_header) + len(pixels), 22)
    # ICONDIR
    icon_dir = struct.pack("<HHH", 0, 1, 1)
    with open(path, "wb") as f:
        f.write(icon_dir)
        f.write(dir_entry)
        f.write(bmp_header)
        f.write(pixels)


make_png(os.path.join(OUT_DIR, "trayTemplate.png"), 32)
make_ico(os.path.join(OUT_DIR, "icon.ico"), 256)

print("assets generated at", OUT_DIR)
