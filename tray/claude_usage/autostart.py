"""Start bij inloggen: register-sleutel op Windows, .desktop-bestand in ~/.config/autostart op Linux."""

from __future__ import annotations

import os
import shlex
import sys
from pathlib import Path

APP_NAME = "ClaudeUsage"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


def launch_command() -> list[str]:
    """Het commando waarmee deze app nu draait: de gebouwde exe, of python + main.py."""
    if getattr(sys, "frozen", False):
        return [sys.executable]
    return [sys.executable, str(Path(__file__).resolve().parent.parent / "main.py")]


def available() -> bool:
    return sys.platform == "win32" or sys.platform.startswith("linux")


# ---------------------------------------------------------------- Linux

def _desktop_file() -> Path:
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "autostart" / "claude-usage.desktop"


def _linux_enabled() -> bool:
    return _desktop_file().is_file()


def _linux_set(enabled: bool) -> None:
    path = _desktop_file()
    if enabled:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=Claude Usage\n"
            "Comment=Claude-gebruik in de taakbalk\n"
            f"Exec={shlex.join(launch_command())}\n"
            "X-GNOME-Autostart-enabled=true\n"
            "Terminal=false\n",
            encoding="utf-8")
    elif path.exists():
        path.unlink()


# ---------------------------------------------------------------- Windows

def _win_enabled() -> bool:
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            winreg.QueryValueEx(key, APP_NAME)
            return True
    except OSError:
        return False


def _win_set(enabled: bool) -> None:
    import subprocess
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
        if enabled:
            winreg.SetValueEx(key, APP_NAME, 0, winreg.REG_SZ, subprocess.list2cmdline(launch_command()))
        else:
            try:
                winreg.DeleteValue(key, APP_NAME)
            except FileNotFoundError:
                pass


# ---------------------------------------------------------------- publiek

def is_enabled() -> bool:
    if sys.platform == "win32":
        return _win_enabled()
    if sys.platform.startswith("linux"):
        return _linux_enabled()
    return False


def set_enabled(enabled: bool) -> None:
    if sys.platform == "win32":
        _win_set(enabled)
    elif sys.platform.startswith("linux"):
        _linux_set(enabled)
