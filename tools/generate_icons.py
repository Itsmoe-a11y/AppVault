#!/usr/bin/env python3
"""
Generates complete iOS AppIcon asset catalog image set for AppVault.
Pure Python standard library (struct + zlib). No third-party dependencies required.
"""
import os
import struct
import zlib

def make_png(w, h, filename):
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type None
        ny = y / float(h)
        for x in range(w):
            nx = x / float(w)

            # Elegant Deep Indigo & Violet Gradient (AppVault Brand)
            r = int(30 + 35 * nx + 15 * ny)
            g = int(27 + 25 * nx + 55 * ny)
            b = int(75 + 130 * ny + 50 * nx)

            # Normalized centered coordinates [-1.0, 1.0]
            cx, cy = (nx - 0.5) * 2.0, (ny - 0.5) * 2.0

            # Subtle squircle border shading
            dist = (cx * cx * cx * cx + cy * cy * cy * cy) ** 0.25
            if dist > 0.88:
                factor = max(0.0, 1.0 - (dist - 0.88) * 4.0)
                r = int(r * (0.6 + 0.4 * factor))
                g = int(g * (0.6 + 0.4 * factor))
                b = int(b * (0.6 + 0.4 * factor))

            # Graphics: Stylized Safe / Vault Box & Keyhole
            # 1. Outer Vault Square
            in_outer_vault = (-0.50 <= cx <= 0.50) and (-0.50 <= cy <= 0.50)
            in_inner_vault = (-0.42 <= cx <= 0.42) and (-0.42 <= cy <= 0.42)
            vault_frame = in_outer_vault and not in_inner_vault

            # 2. Vault Handle / Dial Wheel (Circle)
            r_dial = (cx * cx + cy * cy) ** 0.5
            dial_outer = (0.16 <= r_dial <= 0.24)
            dial_center = (r_dial <= 0.08)

            # 3. Spoke spokes on dial wheel
            dial_spoke = (r_dial <= 0.24) and (abs(cx) <= 0.03 or abs(cy) <= 0.03)

            # 4. Corner rivets on vault
            is_rivet = (
                ((abs(cx - 0.36) <= 0.03 or abs(cx + 0.36) <= 0.03) and
                 (abs(cy - 0.36) <= 0.03 or abs(cy + 0.36) <= 0.03))
            )

            if vault_frame or dial_outer or dial_center or dial_spoke or is_rivet:
                r, g, b = 255, 255, 255

            raw.extend([r, g, b, 255])

    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)

    png = (
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(bytes(raw)))
        + chunk(b'IEND', b'')
    )
    with open(filename, 'wb') as f:
        f.write(png)

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.abspath(os.path.join(script_dir, ".."))
    target_dir = os.path.join(root_dir, "Resources", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(target_dir, exist_ok=True)

    sizes = {
        'icon-20.png': (20, 20),
        'icon-20@2x.png': (40, 40),
        'icon-20@3x.png': (60, 60),
        'icon-29.png': (29, 29),
        'icon-29@2x.png': (58, 58),
        'icon-29@3x.png': (87, 87),
        'icon-40.png': (40, 40),
        'icon-40@2x.png': (80, 80),
        'icon-40@3x.png': (120, 120),
        'icon-60@2x.png': (120, 120),
        'icon-60@3x.png': (180, 180),
        'icon-76.png': (76, 76),
        'icon-76@2x.png': (152, 152),
        'icon-83.5@2x.png': (167, 167),
        'icon-1024.png': (1024, 1024),
    }

    for name, (w, h) in sizes.items():
        out_path = os.path.join(target_dir, name)
        make_png(w, h, out_path)

    print(f"Generated {len(sizes)} icons in {target_dir}")

if __name__ == "__main__":
    main()
