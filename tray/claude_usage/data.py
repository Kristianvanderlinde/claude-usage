"""Gegevens ophalen: planlimieten via de Claude Code-login en tokens uit de lokale logs.

Bronnen:
  - Planlimieten: GET https://api.anthropic.com/api/oauth/usage met het OAuth-token van
    Claude Code (zie credentials.py voor waar dat gezocht wordt). Het token wordt alleen
    gelezen, nooit ververst; dat blijft Claude Code zelf doen.
  - Tokens: de transcripts in ~/.claude/projects/**/*.jsonl.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import credentials

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"


# ---------------------------------------------------------------- modellen

@dataclass
class LimitInfo:
    label: str
    percent: float
    resets_at: datetime | None


@dataclass
class PlanResult:
    limits: list[LimitInfo] = field(default_factory=list)
    error: str | None = None
    subscription: str | None = None
    rate_limited: bool = False
    needs_login: bool = False     # geen login gevonden, of verlopen (401)
    raw: dict | None = None


@dataclass
class TokenTotals:
    input: int = 0
    output: int = 0
    cache_write: int = 0
    cache_read: int = 0

    @property
    def total(self) -> int:
        return self.input + self.output + self.cache_write + self.cache_read

    def add(self, o: "TokenTotals") -> None:
        self.input += o.input
        self.output += o.output
        self.cache_write += o.cache_write
        self.cache_read += o.cache_read


@dataclass
class TokenStats:
    today: TokenTotals = field(default_factory=TokenTotals)
    week: TokenTotals = field(default_factory=TokenTotals)
    today_by_model: dict[str, TokenTotals] = field(default_factory=dict)


# ---------------------------------------------------------------- paden

def config_dirs() -> list[Path]:
    """Mogelijke Claude-configmappen (voor de transcripts in projects/)."""
    home = Path.home()
    dirs = []
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        dirs.append(Path(os.environ["CLAUDE_CONFIG_DIR"]))
    dirs += [home / ".claude", home / ".config" / "claude"]
    return dirs


# ---------------------------------------------------------------- planlimieten

def read_credentials(path: Path | None = None) -> tuple[str | None, str | None]:
    """Geeft (accessToken, subscriptionType) terug, of (None, None).
    Zonder pad worden alle bekende opslagplekken doorzocht."""
    if path is not None:
        try:
            cred = credentials.parse_blob(path.read_bytes(), str(path))
        except OSError:
            cred = None
    else:
        cred = credentials.find_credential()
    return (cred.token, cred.subscription) if cred else (None, None)


def ssl_context() -> ssl.SSLContext:
    """Systeemcertificaten, aangevuld met certifi: een gebundelde app vindt die van het
    systeem niet altijd."""
    ctx = ssl.create_default_context()
    try:
        import certifi
        ctx.load_verify_locations(certifi.where())
    except (ImportError, OSError, ssl.SSLError):
        pass
    return ctx


def parse_date(value) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def limit_label(kind: str, scope: str | None) -> str:
    if kind == "session":
        base = "Sessie (5 uur)"
    elif kind.startswith("weekly"):
        base = "Week"
    else:
        base = kind.capitalize()
    if scope:
        return f"{base} · {scope.capitalize()}"
    if kind.startswith("weekly_") and kind != "weekly_all":
        return f"{base} · {kind[len('weekly_'):].capitalize()}"
    return base


def parse_usage(data: dict) -> list[LimitInfo]:
    # Nieuwere responses hebben een generieke `limits`-lijst; anders five_hour/seven_day.
    limits = data.get("limits")
    if isinstance(limits, list) and limits:
        out = []
        for item in limits:
            pct = item.get("percent")
            if not isinstance(pct, (int, float)):
                continue
            out.append(LimitInfo(limit_label(item.get("kind") or "?", item.get("scope")),
                                 float(pct), parse_date(item.get("resets_at"))))
        return out
    out = []
    for key, label in (("five_hour", "Sessie (5 uur)"), ("seven_day", "Week"),
                       ("seven_day_opus", "Week · Opus"), ("seven_day_sonnet", "Week · Sonnet")):
        o = data.get(key)
        if isinstance(o, dict) and isinstance(o.get("utilization"), (int, float)):
            out.append(LimitInfo(label, float(o["utilization"]), parse_date(o.get("resets_at"))))
    return out


def fetch_plan(creds_path: Path | None = None, url: str = USAGE_URL) -> PlanResult:
    token, subscription = read_credentials(creds_path)
    if not token:
        return PlanResult(error="Geen Claude-login gevonden op deze computer", needs_login=True)
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-usage-tray",
    })
    try:
        with urllib.request.urlopen(req, timeout=20, context=ssl_context()) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code == 429:
            return PlanResult(error="Te veel verzoeken (429)", subscription=subscription, rate_limited=True)
        if e.code == 401:
            return PlanResult(error="Login verlopen. Open Claude Code of log opnieuw in.",
                              subscription=subscription, needs_login=True)
        return PlanResult(error=f"Onverwachte status {e.code}", subscription=subscription)
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        reason = getattr(e, "reason", e)
        return PlanResult(error=f"Netwerkfout: {reason}", subscription=subscription)
    except ValueError:
        return PlanResult(error="Antwoord niet te lezen", subscription=subscription)
    return PlanResult(limits=parse_usage(data), subscription=subscription, raw=data)


# ---------------------------------------------------------------- ophaalschema en bewaren

def state_path() -> Path:
    """Waar de laatste cijfers en de wachttijd bewaard worden."""
    if sys.platform == "win32":
        base = Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming")
        return base / "ClaudeUsage" / "state.json"
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "claude-usage" / "state.json"


class PlanTracker:
    """Bepaalt wanneer de usage-API gevraagd mag worden en onthoudt de laatste goede cijfers.

    Elke 10 minuten; na een 429 oplopend 15, 30 en 60 minuten. Cijfers en wachttijd worden
    bewaard, zodat een herstart niet meteen een nieuw verzoek doet.
    """

    INTERVAL = timedelta(minutes=10)
    BACKOFF = (timedelta(minutes=15), timedelta(minutes=30), timedelta(minutes=60))

    def __init__(self, path: Path | None = None):
        self.path = path or state_path()
        self.limits: list[LimitInfo] | None = None   # None: nog nooit cijfers gehad
        self.fetched_at: datetime | None = None
        self.subscription: str | None = None
        self.error: str | None = None                # alleen als er geen cijfers zijn
        self.warning: str | None = None              # probleem terwijl oude cijfers blijven staan
        self.needs_login = False
        self.next_fetch = datetime.min.replace(tzinfo=timezone.utc)
        self.strikes = 0
        self._raw: dict | None = None
        self._restore()

    def due(self, now: datetime | None = None) -> bool:
        return (now or _now()) >= self.next_fetch

    def started(self, now: datetime | None = None) -> None:
        """Bij het versturen: voorkomt dubbele aanvragen terwijl er een onderweg is."""
        self.next_fetch = (now or _now()) + self.INTERVAL

    def apply(self, result: PlanResult, now: datetime | None = None) -> None:
        now = now or _now()
        if result.subscription:
            self.subscription = result.subscription
        self.needs_login = result.needs_login
        if result.rate_limited:
            self.next_fetch = now + self.BACKOFF[min(self.strikes, len(self.BACKOFF) - 1)]
            self.strikes += 1
            self._problem(self.blocked_message())
        elif result.error:
            self.next_fetch = now + self.INTERVAL
            self._problem(result.error)
        else:
            self.limits, self.fetched_at, self._raw = result.limits, now, result.raw
            self.error = self.warning = None
            self.strikes = 0
            self.next_fetch = now + self.INTERVAL
        self._save()

    def blocked_message(self) -> str:
        return f"Tijdelijk geblokkeerd (te veel verzoeken), opnieuw om {self.next_fetch.astimezone():%H:%M}"

    def _problem(self, msg: str) -> None:
        if self.limits is not None:
            self.warning = msg
        else:
            self.error = msg

    def _save(self) -> None:
        state = {"raw": self._raw, "subscription": self.subscription, "strikes": self.strikes,
                 "fetched_at": self.fetched_at.isoformat() if self.fetched_at else None,
                 "next_fetch": self.next_fetch.isoformat()}
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps(state), encoding="utf-8")
        except OSError:
            pass   # bewaren is een gemak; zonder werkt de app gewoon

    def _restore(self) -> None:
        try:
            state = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        if not isinstance(state, dict):
            return
        self.subscription = state.get("subscription")
        if isinstance(state.get("raw"), dict):
            self._raw = state["raw"]
            self.limits = parse_usage(self._raw)
            self.fetched_at = parse_date(state.get("fetched_at"))
        self.strikes = state.get("strikes") if isinstance(state.get("strikes"), int) else 0
        nxt = parse_date(state.get("next_fetch"))
        if nxt:
            self.next_fetch = nxt
        if self.fetched_at:
            self.next_fetch = max(self.next_fetch, self.fetched_at + self.INTERVAL)
        if self.strikes and self.next_fetch > _now():
            self._problem(self.blocked_message())


def _now() -> datetime:
    return datetime.now(timezone.utc)


# ---------------------------------------------------------------- tokens

def week_start(now: datetime) -> datetime:
    """Maandag 00:00 lokale tijd van de huidige week."""
    start_today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return start_today - timedelta(days=start_today.weekday())


def scan_tokens(project_dirs: list[Path] | None = None, now: datetime | None = None) -> TokenStats:
    now = (now or datetime.now()).astimezone()
    start_today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    start_week = week_start(now)
    dirs = project_dirs if project_dirs is not None else [d / "projects" for d in config_dirs()]

    # Eén bericht kan meerdere regels opleveren (streaming); de laatste wint.
    per_message: dict[str, tuple[datetime, str, TokenTotals]] = {}
    for d in dirs:
        if not d.is_dir():
            continue
        for path in d.rglob("*.jsonl"):
            try:
                if datetime.fromtimestamp(path.stat().st_mtime).astimezone() < start_week:
                    continue
                f = path.open(encoding="utf-8", errors="replace")
            except OSError:
                continue
            with f:
                for line in f:
                    if '"usage"' not in line:
                        continue
                    try:
                        obj = json.loads(line)
                    except ValueError:
                        continue
                    msg = obj.get("message")
                    if not isinstance(msg, dict) or not isinstance(msg.get("usage"), dict):
                        continue
                    when = parse_date(obj.get("timestamp"))
                    if when is None:
                        continue
                    when = when.astimezone()
                    if when < start_week:
                        continue
                    model = msg.get("model") or "onbekend"
                    if model == "<synthetic>":
                        continue
                    u = msg["usage"]

                    def n(k: str) -> int:
                        v = u.get(k)
                        return int(v) if isinstance(v, (int, float)) else 0

                    totals = TokenTotals(n("input_tokens"), n("output_tokens"),
                                         n("cache_creation_input_tokens"), n("cache_read_input_tokens"))
                    key = f"{msg.get('id') or id(obj)}:{obj.get('requestId') or ''}"
                    per_message[key] = (when, model, totals)

    stats = TokenStats()
    for when, model, totals in per_message.values():
        stats.week.add(totals)
        if when >= start_today:
            stats.today.add(totals)
            stats.today_by_model.setdefault(model, TokenTotals()).add(totals)
    return stats


# ---------------------------------------------------------------- opmaak

DAYS = ["ma", "di", "wo", "do", "vr", "za", "zo"]
MONTHS = ["jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"]


def fmt_tokens(n: int) -> str:
    if n >= 1_000_000_000:
        return f"{n / 1_000_000_000:.1f} mld"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}K"
    return str(n)


def fmt_when(d: datetime, now: datetime | None = None) -> str:
    """Vandaag alleen de tijd, anders ook dag en datum: "zo 25 okt 02:59"."""
    now = (now or datetime.now()).astimezone()
    local = d.astimezone()
    if local.date() == now.date():
        return local.strftime("%H:%M")
    return f"{DAYS[local.weekday()]} {local.day} {MONTHS[local.month - 1]} {local.strftime('%H:%M')}"


def fmt_reset(d: datetime, now: datetime | None = None) -> str:
    now = (now or datetime.now()).astimezone()
    local = d.astimezone()
    when = fmt_when(d, now)
    left = int((local - now).total_seconds())
    if left <= 0:
        rest = "nu"
    else:
        h, m = left // 3600, (left % 3600) // 60
        rest = f"over {h // 24}d {h % 24}u" if h >= 24 else (f"over {h}u {m}m" if h else f"over {m}m")
    return f"Reset {when} · {rest}"


def short_model(m: str) -> str:
    return m.replace("claude-", "")


def headline(limits: list[LimitInfo]) -> list[LimitInfo]:
    """Sessie en week voor in het tray-icoon en de tooltip."""
    parts = [next((l for l in limits if l.label.startswith("Sessie")), None),
             next((l for l in limits if l.label == "Week"), None)]
    parts = [p for p in parts if p]
    return parts or limits[:1]
