"""De Claude-login vinden, waar Claude Code (of de Claude-app) hem ook bewaard heeft.

Claude Code bewaart de login als JSON met een `claudeAiOauth`-blok. Afhankelijk van
systeem en versie staat die:
  - in `.credentials.json` in de configmap (~/.claude, $CLAUDE_CONFIG_DIR, ...);
  - op Windows in Credential Manager, doel "Claude Code-credentials";
  - op Linux mogelijk in de sleutelbos (Secret Service, via `secret-tool`).
Gebruikt Claude Code een andere configmap, zoals de Claude-app per werkmap doet, dan krijgt
de naam een achtervoegsel: "Claude Code-credentials-1a2b3c4d". Daarom lezen we alle varianten
en kiezen we de geldige login die het langst geldig is.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

SERVICE = "Claude Code-credentials"


@dataclass
class Credential:
    token: str
    subscription: str | None
    expires_at: datetime | None
    source: str

    @property
    def expired(self) -> bool:
        return self.expires_at is not None and self.expires_at <= datetime.now(timezone.utc)


# ---------------------------------------------------------------- inhoud lezen

def parse_blob(blob: bytes | str, source: str) -> Credential | None:
    """Leest een opgeslagen login. Kan JSON zijn in UTF-8, UTF-16 of hex-gecodeerd."""
    texts: list[str] = []
    if isinstance(blob, str):
        texts.append(blob)
    else:
        for enc in ("utf-8", "utf-16-le"):
            try:
                texts.append(blob.decode(enc))
            except UnicodeDecodeError:
                pass
    for text in texts:
        text = text.strip().strip("\x00")
        if text and all(c in "0123456789abcdefABCDEF" for c in text) and len(text) % 2 == 0:
            try:
                text = bytes.fromhex(text).decode("utf-8")
            except (ValueError, UnicodeDecodeError):
                continue
        try:
            data = json.loads(text)
        except ValueError:
            continue
        oauth = data.get("claudeAiOauth") if isinstance(data, dict) else None
        if not isinstance(oauth, dict) or not isinstance(oauth.get("accessToken"), str):
            continue
        expires = oauth.get("expiresAt")
        expires_at = (datetime.fromtimestamp(expires / 1000, timezone.utc)
                      if isinstance(expires, (int, float)) and expires > 0 else None)
        return Credential(oauth["accessToken"], oauth.get("subscriptionType"), expires_at, source)
    return None


# ---------------------------------------------------------------- bronnen

def config_dirs() -> list[Path]:
    home = Path.home()
    dirs = [Path(os.environ[v]) for v in ("CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR")
            if os.environ.get(v)]
    return dirs + [home / ".claude", home / ".config" / "claude"]


def app_dirs() -> list[Path]:
    """Mappen van de Claude-app, waarin Claude Code per werkmap een eigen configmap kan hebben."""
    home = Path.home()
    if sys.platform == "win32":
        roots = [os.environ.get("APPDATA"), os.environ.get("LOCALAPPDATA")]
        return [Path(r) / name for r in roots if r for name in ("Claude", "AnthropicClaude", "Claude Code")]
    return [home / ".config" / "Claude", home / ".config" / "claude-desktop"]


def credential_files() -> list[Path]:
    files = [d / ".credentials.json" for d in config_dirs()]
    for root in app_dirs():
        if root.is_dir():
            files += _find(root, ".credentials.json", depth=5)
    seen, out = set(), []
    for f in files:
        key = str(f.resolve()) if f.exists() else str(f)
        if key not in seen and f.is_file():
            seen.add(key)
            out.append(f)
    return out


def _find(root: Path, name: str, depth: int) -> list[Path]:
    found = []
    try:
        for entry in os.scandir(root):
            if entry.name == name and entry.is_file():
                found.append(Path(entry.path))
            elif depth > 0 and entry.is_dir(follow_symlinks=False) and not entry.name.startswith("Cache"):
                found += _find(Path(entry.path), name, depth - 1)
    except OSError:
        pass
    return found


def service_names() -> list[str]:
    """De basisnaam plus de variant met hash voor een eigen configmap (zoals Claude Code die maakt)."""
    names = [SERVICE]
    for var in ("CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR"):
        value = os.environ.get(var)
        if value:
            digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:8]
            names.append(f"{SERVICE}-{digest}")
    return names


def windows_entries() -> list[tuple[str, bytes]]:
    """Alle algemene Credential Manager-items met "Claude Code" in de naam."""
    if sys.platform != "win32":
        return []
    import ctypes
    from ctypes import wintypes

    class CREDENTIAL(ctypes.Structure):
        _fields_ = [("Flags", wintypes.DWORD), ("Type", wintypes.DWORD), ("TargetName", wintypes.LPWSTR),
                    ("Comment", wintypes.LPWSTR), ("LastWritten", wintypes.FILETIME),
                    ("CredentialBlobSize", wintypes.DWORD), ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
                    ("Persist", wintypes.DWORD), ("AttributeCount", wintypes.DWORD),
                    ("Attributes", ctypes.c_void_p), ("TargetAlias", wintypes.LPWSTR),
                    ("UserName", wintypes.LPWSTR)]

    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    advapi.CredEnumerateW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
                                      ctypes.POINTER(ctypes.POINTER(ctypes.POINTER(CREDENTIAL)))]
    advapi.CredEnumerateW.restype = wintypes.BOOL
    advapi.CredFree.argtypes = [ctypes.c_void_p]
    count = wintypes.DWORD()
    creds = ctypes.POINTER(ctypes.POINTER(CREDENTIAL))()
    if not advapi.CredEnumerateW(None, 0, ctypes.byref(count), ctypes.byref(creds)):
        return []
    out = []
    try:
        for i in range(count.value):
            c = creds[i].contents
            target = c.TargetName or ""
            if "claude code" in target.lower() and c.CredentialBlobSize:
                out.append((target, ctypes.string_at(c.CredentialBlob, c.CredentialBlobSize)))
    finally:
        advapi.CredFree(creds)
    return out


def secret_service_entries() -> list[tuple[str, str]]:
    """Linux: de sleutelbos via `secret-tool`, als die er is."""
    if not sys.platform.startswith("linux") or not shutil.which("secret-tool"):
        return []
    out = []
    for name in service_names():
        try:
            res = subprocess.run(["secret-tool", "lookup", "service", name], capture_output=True,
                                 text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            continue
        if res.returncode == 0 and res.stdout.strip():
            out.append((f"sleutelbos: {name}", res.stdout))
    return out


# ---------------------------------------------------------------- kiezen

def find_credential() -> Credential | None:
    """De beste login uit alle bronnen: eerst niet-verlopen, dan de langst geldige."""
    found: list[Credential] = []
    for path in credential_files():
        try:
            cred = parse_blob(path.read_bytes(), str(path))
        except OSError:
            continue
        if cred:
            found.append(cred)
    for target, blob in windows_entries() + secret_service_entries():
        cred = parse_blob(blob, target)
        if cred:
            found.append(cred)
    return best(found)


def best(found: list[Credential]) -> Credential | None:
    if not found:
        return None
    floor = datetime.min.replace(tzinfo=timezone.utc)
    return max(found, key=lambda c: (not c.expired, c.expires_at or floor))


# ---------------------------------------------------------------- inloggen

def claude_executable() -> str | None:
    """Pad naar de Claude Code-CLI, ook als PATH (bv. bij autostart) onvolledig is."""
    found = shutil.which("claude")
    if found:
        return found
    home = Path.home()
    if sys.platform == "win32":
        appdata = Path(os.environ.get("APPDATA") or home / "AppData" / "Roaming")
        candidates = [home / ".local" / "bin" / "claude.exe", appdata / "npm" / "claude.cmd"]
    else:
        candidates = [home / ".local" / "bin" / "claude", home / ".claude" / "local" / "claude",
                      Path("/usr/local/bin/claude"), Path("/usr/bin/claude")]
    for c in candidates:
        if c.is_file():
            return str(c)
    return None


def start_login() -> str | None:
    """Opent een terminal met `claude auth login`. Geeft een foutmelding terug, of None."""
    exe = claude_executable()
    if not exe:
        return "Claude Code is niet gevonden. Installeer het eerst en log daarin in."
    if sys.platform == "win32":
        try:
            # De buitenste cmd zonder venster; `start` opent een eigen console voor het inloggen.
            subprocess.Popen(f'cmd.exe /c start "Claude inloggen" cmd.exe /k ""{exe}" auth login"',
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except OSError as e:
            return f"Kon geen terminal openen: {e}"
        return None
    script = f'"{exe}" auth login; echo; read -p "Klaar? Druk op Enter om dit venster te sluiten."'
    # Per terminal de manier om een commando met argumenten mee te geven.
    terminals = (("gnome-terminal", ["--"]), ("ptyxis", ["--"]), ("kgx", ["--"]), ("tilix", ["--"]),
                 ("konsole", ["-e"]), ("xfce4-terminal", ["-x"]), ("x-terminal-emulator", ["-e"]),
                 ("alacritty", ["-e"]), ("kitty", []), ("xterm", ["-e"]))
    for term, flag in terminals:
        path = shutil.which(term)
        if not path:
            continue
        args = [path, *flag, "bash", "-lc", script]
        try:
            subprocess.Popen(args, start_new_session=True)
        except OSError:
            continue
        return None
    return f"Geen terminal gevonden. Voer zelf uit: {exe} auth login"
