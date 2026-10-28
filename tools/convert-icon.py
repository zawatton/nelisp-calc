"""Convert the original generated PNG to a Windows icon without repainting."""
import hashlib
import json
from pathlib import Path

from PIL import Image, __version__ as pillow_version

assets = Path(__file__).resolve().parents[1] / "assets"
source = assets / "nelisp-calc.png"
destination = assets / "nelisp-calc.ico"
sizes = [(n, n) for n in (16, 24, 32, 48, 64, 128, 256)]
with Image.open(source) as original:
    if original.width != original.height or original.width < 256:
        raise ValueError("Source must be square and at least 256 pixels")
    if "A" not in original.getbands():
        raise ValueError("Source must retain its original alpha channel")
    original.convert("RGBA").save(destination, format="ICO", sizes=sizes,
                                  bitmap_format="bmp")
with Image.open(destination) as icon:
    if icon.ico.sizes() != set(sizes):
        raise ValueError("ICO frame sizes differ from the required set")
    alpha_ranges = {str(n): icon.ico.getimage((n, n)).getchannel("A").getextrema()
                    for n, _ in sizes}
    if any(low == high for low, high in alpha_ranges.values()):
        raise ValueError("Every ICO frame must retain transparency and visible pixels")
record = {
    "source": source.name,
    "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
    "output": destination.name,
    "output_sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
    "conversion": "python tools/convert-icon.py; Pillow RGBA DIB ICO export only",
    "pillow_version": pillow_version,
    "sizes": [n for n, _ in sizes],
    "alpha_ranges": alpha_ranges,
}
(assets / "nelisp-calc-icon-conversion.json").write_text(
    json.dumps(record, indent=2) + "\n", encoding="utf-8")
print("ICON-CONVERT-PASS frames=7 sizes=16,24,32,48,64,128,256")
