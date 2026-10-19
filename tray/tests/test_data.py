"""Tests voor de datalaag en autostart. Draaien: python -m unittest discover tests"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from claude_usage import autostart, data  # noqa: E402

NEW_STYLE = {
    "five_hour": {"utilization": 22.0, "resets_at": "2026-10-19T11:39:59.766103+00:00"},
    "seven_day": {"utilization": 4.0, "resets_at": "2026-10-25T01:59:59.766128+00:00"},
    "limits": [
        {"kind": "session", "percent": 22, "resets_at": "2026-10-19T11:39:59.766103+00:00", "scope": None},
        {"kind": "weekly_all", "percent": 4, "resets_at": "2026-10-25T01:59:59.766128+00:00", "scope": None},
        {"kind": "weekly_opus", "percent": 12, "resets_at": None, "scope": None},
        {"kind": "weekly_x", "percent": "kapot"},
    ],
}


class ParseTests(unittest.TestCase):
    def test_limits_list(self):
        limits = data.parse_usage(NEW_STYLE)
        self.assertEqual([l.label for l in limits], ["Sessie (5 uur)", "Week", "Week · Opus"])
        self.assertEqual(limits[0].percent, 22)
        self.assertEqual(limits[0].resets_at, datetime(2026, 10, 19, 11, 39, 59, 766103, tzinfo=timezone.utc))
        self.assertIsNone(limits[2].resets_at)

    def test_fallback_without_limits_list(self):
        limits = data.parse_usage({"five_hour": {"utilization": 50, "resets_at": "2026-10-19T11:00:00Z"},
                                   "seven_day_opus": {"utilization": 10}, "seven_day": None})
        self.assertEqual([(l.label, l.percent) for l in limits], [("Sessie (5 uur)", 50), ("Week · Opus", 10)])

    def test_empty_and_garbage(self):
        self.assertEqual(data.parse_usage({}), [])
        self.assertEqual(data.parse_usage({"limits": []}), [])
        self.assertEqual(data.parse_usage({"five_hour": "x"}), [])
        self.assertIsNone(data.parse_date("geen datum"))
        self.assertIsNone(data.parse_date(None))

    def test_scope_label(self):
        self.assertEqual(data.limit_label("weekly_all", "sonnet"), "Week · Sonnet")

    def test_headline(self):
        limits = data.parse_usage(NEW_STYLE)
        self.assertEqual([l.label for l in data.headline(limits)], ["Sessie (5 uur)", "Week"])
        only = [data.LimitInfo("Iets", 3, None)]
        self.assertEqual(data.headline(only), only)
        self.assertEqual(data.headline([]), [])


class CredentialTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / ".credentials.json"

    def tearDown(self):
        self.tmp.cleanup()

    def test_missing_file(self):
        self.assertEqual(data.read_credentials(self.path), (None, None))

    def test_invalid_json(self):
        self.path.write_text("{kapot")
        self.assertEqual(data.read_credentials(self.path), (None, None))

    def test_no_oauth_block(self):
        self.path.write_text(json.dumps({"mcpOAuth": {}}))
        self.assertEqual(data.read_credentials(self.path), (None, None))

    def test_ok(self):
        self.path.write_text(json.dumps({"claudeAiOauth": {"accessToken": "abc", "subscriptionType": "team"}}))
        self.assertEqual(data.read_credentials(self.path), ("abc", "team"))

    def test_config_dir_env(self):
        (Path(self.tmp.name) / ".credentials.json").write_text("{}")
        with mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": self.tmp.name}):
            self.assertEqual(data.credentials_path(), self.path)


class FakeApi(BaseHTTPRequestHandler):
    status = 200
    body = json.dumps(NEW_STYLE).encode()
    seen_auth = None

    def do_GET(self):  # noqa: N802
        FakeApi.seen_auth = (self.headers.get("Authorization"), self.headers.get("anthropic-beta"))
        self.send_response(FakeApi.status)
        self.end_headers()
        self.wfile.write(FakeApi.body)

    def log_message(self, *args):
        pass


class FetchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), FakeApi)
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/usage"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.creds = Path(self.tmp.name) / ".credentials.json"
        self.creds.write_text(json.dumps({"claudeAiOauth": {"accessToken": "tok", "subscriptionType": "max"}}))
        FakeApi.status, FakeApi.body = 200, json.dumps(NEW_STYLE).encode()

    def tearDown(self):
        self.tmp.cleanup()

    def test_ok(self):
        r = data.fetch_plan(self.creds, self.url)
        self.assertIsNone(r.error)
        self.assertEqual(r.raw, NEW_STYLE)
        self.assertEqual(r.subscription, "max")
        self.assertEqual(len(r.limits), 3)
        self.assertEqual(FakeApi.seen_auth, ("Bearer tok", "oauth-2025-04-20"))

    def test_http_errors(self):
        for status, expected in ((401, "Login verlopen"), (429, "(429)"), (500, "status 500")):
            FakeApi.status = status
            r = data.fetch_plan(self.creds, self.url)
            self.assertIn(expected, r.error)
            self.assertEqual(r.limits, [])
            self.assertEqual(r.rate_limited, status == 429)

    def test_bad_body(self):
        FakeApi.body = b"<html>"
        self.assertEqual(data.fetch_plan(self.creds, self.url).error, "Antwoord niet te lezen")

    def test_no_login(self):
        self.creds.unlink()
        with mock.patch.object(data, "credentials_path", return_value=None):
            self.assertEqual(data.fetch_plan(None, self.url).error, "Geen Claude Code-login gevonden")

    def test_network_down(self):
        r = data.fetch_plan(self.creds, "http://127.0.0.1:9/usage")
        self.assertTrue(r.error.startswith("Netwerkfout"))


class TrackerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "sub" / "state.json"
        self.t0 = datetime(2026, 10, 19, 10, 0, tzinfo=timezone.utc)
        self.ok = data.PlanResult(limits=data.parse_usage(NEW_STYLE), raw=NEW_STYLE, subscription="team")
        self.blocked = data.PlanResult(error="Te veel verzoeken (429)", rate_limited=True)

    def tearDown(self):
        self.tmp.cleanup()

    def test_backoff_steps(self):
        tr = data.PlanTracker(self.path)
        self.assertTrue(tr.due(self.t0))
        waits = []
        for _ in range(4):
            tr.apply(self.blocked, self.t0)
            waits.append(int((tr.next_fetch - self.t0).total_seconds() // 60))
        self.assertEqual(waits, [15, 30, 60, 60])
        self.assertIsNone(tr.limits)
        self.assertIn("Tijdelijk geblokkeerd", tr.error)
        tr.apply(self.ok, self.t0)
        self.assertEqual((tr.strikes, tr.error, tr.warning), (0, None, None))
        self.assertEqual(tr.next_fetch - self.t0, timedelta(minutes=10))
        self.assertFalse(tr.due(self.t0 + timedelta(minutes=9)))
        self.assertTrue(tr.due(self.t0 + timedelta(minutes=10)))

    def test_problem_keeps_old_numbers(self):
        tr = data.PlanTracker(self.path)
        tr.apply(self.ok, self.t0)
        tr.apply(self.blocked, self.t0 + timedelta(minutes=10))
        self.assertEqual(len(tr.limits), 3)
        self.assertIsNone(tr.error)
        self.assertIn("Tijdelijk geblokkeerd", tr.warning)
        tr.apply(data.PlanResult(error="Netwerkfout: x"), self.t0 + timedelta(minutes=30))
        self.assertEqual(tr.warning, "Netwerkfout: x")
        self.assertEqual(tr.fetched_at, self.t0)

    def test_started_prevents_double_fetch(self):
        tr = data.PlanTracker(self.path)
        tr.started(self.t0)
        self.assertFalse(tr.due(self.t0 + timedelta(minutes=1)))

    def test_restart_restores_numbers_and_waits(self):
        now = datetime.now(timezone.utc)
        tr = data.PlanTracker(self.path)
        tr.apply(self.ok, now - timedelta(minutes=3))
        again = data.PlanTracker(self.path)
        self.assertEqual([l.percent for l in again.limits], [22, 4, 12])
        self.assertEqual(again.subscription, "team")
        self.assertEqual(again.fetched_at, now - timedelta(minutes=3))
        self.assertFalse(again.due(now))                       # cijfers nog vers: niet meteen vragen
        self.assertTrue(again.due(now + timedelta(minutes=7)))

    def test_restart_during_block(self):
        now = datetime.now(timezone.utc)
        data.PlanTracker(self.path).apply(self.blocked, now)
        again = data.PlanTracker(self.path)
        self.assertEqual(again.strikes, 1)
        self.assertFalse(again.due(now + timedelta(minutes=14)))
        self.assertIn("Tijdelijk geblokkeerd", again.error)

    def test_bad_or_unwritable_state(self):
        self.path.parent.mkdir(parents=True)
        for content in ("{kapot", "[1, 2]", json.dumps({"raw": "x", "strikes": "y", "next_fetch": 5})):
            self.path.write_text(content)
            tr = data.PlanTracker(self.path)
            self.assertIsNone(tr.limits)
            self.assertEqual(tr.strikes, 0)
            self.assertTrue(tr.due())
        blocker = Path(self.tmp.name) / "bestand"
        blocker.write_text("geen map")
        tr = data.PlanTracker(blocker / "state.json")   # map is eigenlijk een bestand
        tr.apply(self.ok, self.t0)                       # bewaren mislukt stil
        self.assertEqual(len(tr.limits), 3)


def line(ts: datetime, msg_id: str, req: str, model: str = "claude-opus-5-5", out: int = 10, **extra) -> str:
    usage = {"input_tokens": 1, "output_tokens": out, "cache_creation_input_tokens": 100,
             "cache_read_input_tokens": 1000}
    return json.dumps({"type": "assistant", "timestamp": ts.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
                       "requestId": req, "message": {"id": msg_id, "model": model, "usage": usage}, **extra})


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "projects"
        (self.dir / "proj" / "sub").mkdir(parents=True)
        # Woensdag middag, zodat "eerder deze week" en "vorige week" allebei bestaan.
        self.now = datetime(2026, 10, 21, 15, 0).astimezone()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel: str, lines: list[str], mtime: datetime | None = None):
        p = self.dir / rel
        p.write_text("\n".join(lines) + "\n")
        if mtime:
            os.utime(p, (mtime.timestamp(), mtime.timestamp()))

    def test_scan(self):
        today = self.now - timedelta(hours=1)
        monday = self.now - timedelta(days=2)
        last_week = self.now - timedelta(days=5)
        self.write("proj/a.jsonl", [
            line(today, "m1", "r1", out=5),
            line(today, "m1", "r1", out=50),           # streaming-update van hetzelfde bericht: laatste wint
            line(today, "m2", "r2", model="claude-sonnet-5-5"),
            line(today, "m3", "r3", model="<synthetic>"),
            line(monday, "m4", "r4"),
            line(last_week, "m5", "r5"),               # vorige week: telt niet mee
            "{kapotte regel met \"usage\"",
            json.dumps({"type": "user", "message": {"content": "hoi"}}),
        ], mtime=self.now)
        self.write("proj/sub/b.jsonl", [line(today, "m6", "r6")], mtime=self.now)
        self.write("proj/oud.jsonl", [line(today, "m7", "r7")], mtime=last_week)  # bestand zelf te oud

        stats = data.scan_tokens([self.dir, Path(self.tmp.name) / "bestaat-niet"], now=self.now)
        per_msg = 1 + 100 + 1000
        self.assertEqual(stats.today.output, 50 + 10 + 10)
        self.assertEqual(stats.today.total, 3 * per_msg + 70)
        self.assertEqual(stats.week.total, stats.today.total + per_msg + 10)
        self.assertEqual(stats.today_by_model["claude-opus-5-5"].output, 60)
        self.assertNotIn("<synthetic>", stats.today_by_model)

    def test_empty(self):
        stats = data.scan_tokens([self.dir], now=self.now)
        self.assertEqual(stats.week.total, 0)
        self.assertEqual(stats.today_by_model, {})


class FormatTests(unittest.TestCase):
    def test_tokens(self):
        self.assertEqual([data.fmt_tokens(n) for n in (5, 1500, 2_500_000, 3_000_000_000)],
                         ["5", "2K", "2.5M", "3.0 mld"])

    def test_when(self):
        now = datetime(2026, 10, 5, 10, 0).astimezone()
        self.assertEqual(data.fmt_when(now.replace(hour=8, minute=7), now), "08:07")
        self.assertEqual(data.fmt_when(now - timedelta(days=1), now), "zo 4 okt 10:00")

    def test_reset(self):
        now = datetime(2026, 10, 5, 10, 0).astimezone()   # geen klokwissel in de week erna
        self.assertEqual(data.fmt_reset(now + timedelta(hours=2, minutes=5), now), "Reset 12:05 · over 2u 5m")
        self.assertEqual(data.fmt_reset(now + timedelta(days=6, hours=1), now), "Reset zo 11 okt 11:00 · over 6d 1u")
        self.assertEqual(data.fmt_reset(now - timedelta(minutes=1), now), "Reset 09:59 · nu")


class AutostartLinuxTests(unittest.TestCase):
    def test_toggle(self):
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": tmp}), \
                mock.patch.object(sys, "platform", "linux"):
            self.assertTrue(autostart.available())
            self.assertFalse(autostart.is_enabled())
            autostart.set_enabled(True)
            self.assertTrue(autostart.is_enabled())
            content = (Path(tmp) / "autostart" / "claude-usage.desktop").read_text()
            self.assertIn("Exec=", content)
            self.assertIn("main.py", content)
            autostart.set_enabled(False)
            self.assertFalse(autostart.is_enabled())
            autostart.set_enabled(False)   # nogmaals uit: geen fout


if __name__ == "__main__":
    unittest.main()
