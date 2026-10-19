"""Gegevens ophalen: planlimieten via de Claude Code-login en tokens uit de lokale logs.

Bronnen:
  - Planlimieten: GET https://api.anthropic.com/api/oauth/usage met het OAuth-token dat
    Claude Code op Windows en Linux bewaart in ~/.claude/.credentials.json. Het token wordt
    alleen gelezen, nooit ververst; dat blijft Claude Code zelf doen.
  - Tokens: de transcripts in ~/.claude/projects/**/*.jsonl.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

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
    """Mogelijke Claude-configmappen, de eerste die bestaat wint voor de login."""
    home = Path.home()
    dirs = []
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        dirs.append(Path(os.environ["CLAUDE_CONFIG_DIR"]))
    dirs += [home / ".claude", home / ".config" / "claude"]
    return dirs


def credentials_path() -> Path | None:
    for d in config_dirs():
        p = d / ".credentials.json"
        if p.is_file():
            return p
    return None


# ---------------------------------------------------------------- planlimieten

def read_credentials(path: Path | None = None) -> tuple[str | None, str | None]:
    """Geeft (accessToken, subscriptionType) terug, of (None, None)."""
    path = path or credentials_path()
    if not path:
        return None, None
    try:
        oauth = json.loads(path.read_text(encoding="utf-8")).get("claudeAiOauth") or {}
    except (OSError, ValueError):
        return None, None
    return oauth.get("accessToken"), oauth.get("subscriptionType")


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


def fetch_plan(credentials: Path | None = None, url: str = USAGE_URL) -> PlanResult:
    token, subscription = read_credentials(credentials)
    if not token:
        return PlanResult(error="Geen Claude Code-login gevonden")
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-usage-tray",
    })
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        messages = {401: "Login verlopen — open Claude Code om te verversen",
                    429: "Even te vaak opgevraagd (429), probeer later"}
        return PlanResult(error=messages.get(e.code, f"Onverwachte status {e.code}"),
                          subscription=subscription)
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        reason = getattr(e, "reason", e)
        return PlanResult(error=f"Netwerkfout: {reason}", subscription=subscription)
    except ValueError:
        return PlanResult(error="Antwoord niet te lezen", subscription=subscription)
    return PlanResult(limits=parse_usage(data), subscription=subscription)


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


def fmt_reset(d: datetime, now: datetime | None = None) -> str:
    now = (now or datetime.now()).astimezone()
    local = d.astimezone()
    if local.date() == now.date():
        when = local.strftime("%H:%M")
    else:
        when = f"{DAYS[local.weekday()]} {local.day} {MONTHS[local.month - 1]} {local.strftime('%H:%M')}"
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
