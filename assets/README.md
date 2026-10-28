# Application icon

`nelisp-calc.png` is the original artwork generated with the built-in
`image_gen` tool. `icon-prompt.txt` records its generation prompt.
The source PNG is preserved unchanged, including its alpha channel.

Run `python tools/convert-icon.py` with Pillow installed to reproduce
`nelisp-calc.ico` and `nelisp-calc-icon-conversion.json`. Conversion only
resizes and encodes the original RGBA image as seven Windows DIB icon
frames: 16, 24, 32, 48, 64, 128, and 256 pixels. The JSON records source
and output SHA-256 hashes, Pillow version, and each frame's alpha range.

`build.el` compiles `nelisp-calc.rc` through MinGW `windres` and links the
COFF resource into the executable. Native startup loads resource 1 for
the small and large window icons before the presentation branch.
`tools/icon-probe.ps1` checks PE resources, shell extraction, and a hidden
native window's icon readback. Pass `-NegativeExe` with a pre-icon build
to check that its application icon resource is absent.
