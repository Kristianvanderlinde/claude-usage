"""Startpunt: python main.py (of de gebouwde ClaudeUsage-exe)."""

import os
import sys

# Onder Wayland mag een app zijn eigen venster niet positioneren; via XWayland wel,
# zodat het paneel netjes bij het tray-icoon verschijnt.
if sys.platform.startswith("linux") and os.environ.get("XDG_SESSION_TYPE") == "wayland":
    os.environ.setdefault("QT_QPA_PLATFORM", "xcb")

from claude_usage.app import run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run())
