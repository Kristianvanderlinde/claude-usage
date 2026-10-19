"""Schrijft assets/icon.png en assets/icon.ico (gebruikt door de Windows-build)."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from PySide6.QtGui import QGuiApplication  # noqa: E402

from claude_usage import icons  # noqa: E402

app = QGuiApplication(sys.argv)
out = Path(__file__).resolve().parent.parent / "assets"
out.mkdir(exist_ok=True)
for path, size in ((out / "icon.png", 512), (out / "icon.ico", 256)):
    if not icons.app_image(size).save(str(path)):
        sys.exit(f"Kon {path} niet schrijven")
    print(f"Geschreven: {path}")
