"""Tray-icoon en paneel (Qt) voor Windows en Ubuntu."""

from __future__ import annotations

import math
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

from PySide6.QtCore import QObject, QPointF, QRect, QRectF, QSize, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import (QColor, QCursor, QDesktopServices, QGuiApplication, QKeySequence, QPainter,
                           QPainterPath, QPen, QPixmap, QShortcut)
from PySide6.QtWidgets import (QApplication, QFrame, QGraphicsDropShadowEffect, QHBoxLayout,
                               QLabel, QMenu, QSystemTrayIcon, QVBoxLayout, QWidget)

from . import autostart, data, icons

TOKEN_INTERVAL = 60      # tokens tellen (lokaal); de usage-API volgt data.PlanTracker
USAGE_PAGE = "https://claude.ai/settings/usage"


# ---------------------------------------------------------------- thema

def is_dark() -> bool:
    try:
        return QGuiApplication.styleHints().colorScheme() == Qt.ColorScheme.Dark
    except AttributeError:   # Qt < 6.5
        return QGuiApplication.palette().window().color().lightness() < 128


def theme() -> dict[str, str]:
    if is_dark():
        return dict(bg="#2b2b2d", border="rgba(255,255,255,0.12)", card="rgba(255,255,255,0.06)",
                    text="#f2f2f2", muted="#a1a1a6", track="rgba(255,255,255,0.12)",
                    hover="rgba(255,255,255,0.10)", divider="rgba(255,255,255,0.12)")
    return dict(bg="#f6f6f6", border="rgba(0,0,0,0.12)", card="rgba(0,0,0,0.05)",
                text="#1d1d1f", muted="#6e6e73", track="rgba(0,0,0,0.10)",
                hover="rgba(0,0,0,0.07)", divider="rgba(0,0,0,0.10)")


def css(color: QColor) -> str:
    return color.name()


# ---------------------------------------------------------------- kleine widgets

class Bar(QWidget):
    def __init__(self, percent: float, track: str):
        super().__init__()
        self.percent, self.track = percent, _rgba(track)
        self.setFixedHeight(6)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setPen(Qt.PenStyle.NoPen)
        r = QRectF(self.rect())
        p.setBrush(self.track)
        p.drawRoundedRect(r, 3, 3)
        if self.percent > 0:
            w = max(6.0, r.width() * min(self.percent, 100) / 100)
            p.setBrush(icons.level_color(self.percent))
            p.drawRoundedRect(QRectF(0, 0, w, r.height()), 3, 3)


def _rgba(s: str) -> QColor:
    r, g, b, a = [x.strip() for x in s[s.index("(") + 1:s.index(")")].split(",")]
    return QColor(int(r), int(g), int(b), int(float(a) * 255))


class IconButton(QWidget):
    """Getekende icoonknop (geen afhankelijkheid van lettertype-symbolen)."""
    clicked = Signal()

    def __init__(self, kind: str, tooltip: str, t: dict[str, str]):
        super().__init__()
        self.kind, self.t, self.hover, self.enabled = kind, t, False, True
        self.setFixedSize(28, 28)
        self.setToolTip(tooltip)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def setEnabled(self, on: bool):  # noqa: N802 (Qt-naam)
        self.enabled = on
        self.update()

    def enterEvent(self, _):
        self.hover = True
        self.update()

    def leaveEvent(self, _):
        self.hover = False
        self.update()

    def mouseReleaseEvent(self, e):
        if self.enabled and self.rect().contains(e.position().toPoint()):
            self.clicked.emit()

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        if self.hover and self.enabled:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(_rgba(self.t["hover"]))
            p.drawRoundedRect(QRectF(self.rect()), 7, 7)
        color = QColor(self.t["text"])
        color.setAlphaF(0.8 if self.enabled else 0.35)
        pen = QPen(color, 1.6)
        pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
        p.setPen(pen)
        p.setBrush(Qt.BrushStyle.NoBrush)
        c, r = QPointF(14, 14), 6.0
        box = QRectF(c.x() - r, c.y() - r, 2 * r, 2 * r)
        if self.kind == "refresh":
            p.drawArc(box, 70 * 16, 290 * 16)
            tip = QPointF(c.x() + r * math.cos(math.radians(70)), c.y() - r * math.sin(math.radians(70)))
            p.drawLine(tip, tip + QPointF(-3.5, -1.2))
            p.drawLine(tip, tip + QPointF(-0.8, 3.4))
        elif self.kind == "open":
            p.drawRoundedRect(QRectF(8, 10, 10, 10), 2, 2)
            p.drawLine(QPointF(13, 15), QPointF(20, 8))
            p.drawLine(QPointF(20, 8), QPointF(16, 8))
            p.drawLine(QPointF(20, 8), QPointF(20, 12))
        elif self.kind == "power":
            p.drawArc(box, 120 * 16, 300 * 16)
            p.drawLine(QPointF(14, 6.5), QPointF(14, 13))


class CheckToggle(QWidget):
    """Getekend vinkje met tekst, in dezelfde stijl als de icoonknoppen."""
    toggled = Signal(bool)

    def __init__(self, text: str, checked: bool, t: dict[str, str]):
        super().__init__()
        self.text, self.checked, self.t, self.hover = text, checked, t, False
        font = self.font()
        font.setPixelSize(12)
        self.setFont(font)
        self.setFixedHeight(28)
        self.setFixedWidth(self.fontMetrics().horizontalAdvance(text) + 30)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def setChecked(self, on: bool):  # noqa: N802 (Qt-naam)
        self.checked = on
        self.update()

    def enterEvent(self, _):
        self.hover = True
        self.update()

    def leaveEvent(self, _):
        self.hover = False
        self.update()

    def mouseReleaseEvent(self, e):
        if self.rect().contains(e.position().toPoint()):
            self.checked = not self.checked
            self.update()
            self.toggled.emit(self.checked)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        if self.hover:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(_rgba(self.t["hover"]))
            p.drawRoundedRect(QRectF(self.rect()), 7, 7)
        box = QRectF(2, 7, 14, 14)   # vrijwel gelijk met de linkerrand van de kaarten
        if self.checked:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(icons.CLAUDE)
            p.drawRoundedRect(box, 3, 3)
            pen = QPen(icons.CREAM, 1.8)
            pen.setCapStyle(Qt.PenCapStyle.RoundCap)
            pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
            p.setPen(pen)
            p.drawPolyline([QPointF(5.5, 14.2), QPointF(8, 16.8), QPointF(12.8, 11)])
        else:
            p.setPen(QPen(QColor(self.t["muted"]), 1.4))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawRoundedRect(box.adjusted(0.7, 0.7, -0.7, -0.7), 3, 3)
        color = QColor(self.t["text"])
        color.setAlphaF(0.85)
        p.setPen(color)
        p.drawText(QRectF(22, 0, self.width() - 22, self.height()),
                   Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft, self.text)


class Card(QFrame):
    def __init__(self, t: dict[str, str]):
        super().__init__()
        self.setObjectName("card")
        self.setStyleSheet(f"#card {{ background: {t['card']}; border-radius: 10px; }}")
        self.box = QVBoxLayout(self)
        self.box.setContentsMargins(12, 12, 12, 12)
        self.box.setSpacing(10)


def label(text: str, size: int, color: str, bold: bool = False, align=None) -> QLabel:
    lab = QLabel(text)
    lab.setStyleSheet(f"color: {color}; font-size: {size}px; font-weight: {600 if bold else 400};"
                      " background: transparent;")
    if align is not None:
        lab.setAlignment(align)
    return lab


def row(*widgets, stretch_at: int | None = None) -> QHBoxLayout:
    h = QHBoxLayout()
    h.setContentsMargins(0, 0, 0, 0)
    for i, w in enumerate(widgets):
        if stretch_at == i:
            h.addStretch(1)
        h.addWidget(w)
    if stretch_at == len(widgets):
        h.addStretch(1)
    return h


# ---------------------------------------------------------------- paneel

class Panel(QWidget):
    refresh_requested = Signal()
    quit_requested = Signal()

    def __init__(self):
        super().__init__(None, Qt.WindowType.Popup | Qt.WindowType.FramelessWindowHint)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.closed_at = 0.0
        outer = QVBoxLayout(self)
        outer.setContentsMargins(14, 14, 14, 14)   # ruimte voor de schaduw
        self.frame = QFrame()
        self.frame.setObjectName("panel")
        shadow = QGraphicsDropShadowEffect(blurRadius=24, offset=QPointF(0, 4))
        shadow.setColor(QColor(0, 0, 0, 90))
        self.frame.setGraphicsEffect(shadow)
        outer.addWidget(self.frame)
        self.content: QWidget | None = None
        QShortcut(QKeySequence("Ctrl+R"), self, activated=self.refresh_requested.emit)
        QShortcut(QKeySequence("Ctrl+Q"), self, activated=self.quit_requested.emit)
        QShortcut(QKeySequence("Esc"), self, activated=self.close)

    def hideEvent(self, e):
        self.closed_at = time.monotonic()
        super().hideEvent(e)

    def render(self, state: "State"):
        t = theme()
        self.frame.setStyleSheet(f"#panel {{ background: {t['bg']}; border: 1px solid {t['border']};"
                                 " border-radius: 12px; }")
        if self.frame.layout() is None:
            lay = QVBoxLayout(self.frame)
            lay.setContentsMargins(0, 0, 0, 0)
        if self.content is not None:
            self.content.deleteLater()
        self.content = QWidget()
        self.content.setFixedWidth(320)
        self.content.setStyleSheet("background: transparent;")
        v = QVBoxLayout(self.content)
        v.setContentsMargins(16, 16, 16, 12)
        v.setSpacing(14)

        # Kop
        logo = QLabel()
        logo.setPixmap(QPixmap.fromImage(icons.app_image(64)).scaled(
            30, 30, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))
        titles = QVBoxLayout()
        titles.setSpacing(1)
        titles.addWidget(label("Claude-gebruik", 15, t["text"], bold=True))
        if state.plan.subscription:
            titles.addWidget(label(f"{state.plan.subscription.capitalize()}-abonnement", 11, t["muted"]))
        head = QHBoxLayout()
        head.setSpacing(10)
        head.addWidget(logo)
        head.addLayout(titles)
        head.addStretch(1)
        v.addLayout(head)

        # Planlimieten
        plan = state.plan
        section = self._section("PLANLIMIETEN", t)
        if plan.fetched_at:
            section.addWidget(label(f"stand van {data.fmt_when(plan.fetched_at)}", 11, t["muted"]))
        v.addLayout(section)
        card = Card(t)
        card.box.setSpacing(14)
        if plan.limits is None and plan.error:
            card.box.addWidget(self._warning(plan.error, 12))
        elif plan.limits is None:
            card.box.addWidget(label("Laden…", 13, t["muted"]))
        else:
            if not plan.limits:
                card.box.addWidget(label("Geen limieten gemeld", 13, t["muted"]))
            for lim in plan.limits:
                block = QVBoxLayout()
                block.setSpacing(6)
                block.addLayout(row(label(lim.label, 13, t["text"], bold=True),
                                    label(f"{round(lim.percent)}%", 20, css(icons.level_color(lim.percent)), True),
                                    stretch_at=1))
                block.addWidget(Bar(lim.percent, t["track"]))
                if lim.resets_at:
                    block.addWidget(label(data.fmt_reset(lim.resets_at), 11, t["muted"]))
                card.box.addLayout(block)
            if plan.warning:
                card.box.addWidget(self._warning(plan.warning, 11))
        v.addWidget(card)

        # Tokens
        v.addLayout(self._section("CLAUDE CODE-TOKENS", t))
        card = Card(t)
        tok = state.tokens
        if tok is None:
            card.box.addWidget(label("Laden…", 13, t["muted"]))
        else:
            card.box.addLayout(row(label("Vandaag", 13, t["text"], bold=True),
                                   label(data.fmt_tokens(tok.today.total), 20, t["text"], True), stretch_at=1))
            stats = QHBoxLayout()
            for name, val in (("Invoer", tok.today.input), ("Uitvoer", tok.today.output),
                              ("Cache", tok.today.cache_write + tok.today.cache_read)):
                col = QVBoxLayout()
                col.setSpacing(2)
                col.addWidget(label(name, 10, t["muted"]))
                col.addWidget(label(data.fmt_tokens(val), 13, t["text"], bold=True))
                stats.addLayout(col, 1)
            card.box.addLayout(stats)
            if tok.today_by_model:
                card.box.addWidget(self._divider(t))
                for model, mt in sorted(tok.today_by_model.items(), key=lambda kv: -kv[1].total):
                    dot = label("●", 9, css(icons.CLAUDE))
                    card.box.addLayout(row(dot, label(data.short_model(model), 12, t["text"]),
                                           label(data.fmt_tokens(mt.total), 12, t["text"]), stretch_at=2))
            card.box.addWidget(self._divider(t))
            card.box.addLayout(row(label("Deze week", 12, t["text"]),
                                   label(data.fmt_tokens(tok.week.total), 12, t["text"], True), stretch_at=1))
        v.addWidget(card)

        # Bijgewerkt, streep, voetregel
        if state.last_update:
            upd = label(f"Bijgewerkt {state.last_update.strftime('%H:%M')}", 11, t["muted"],
                        align=Qt.AlignmentFlag.AlignCenter)
            v.addWidget(upd)
        v.addWidget(self._divider(t))

        foot = QHBoxLayout()
        foot.setSpacing(4)
        if autostart.available():
            check = CheckToggle("Start bij inloggen", autostart.is_enabled(), t)
            check.setToolTip("Open Claude Usage automatisch als je inlogt")
            check.toggled.connect(lambda on, c=check: self._toggle_autostart(c, on))
            foot.addWidget(check)
        foot.addStretch(1)
        refresh = IconButton("refresh", "Nu verversen (Ctrl+R)", t)
        refresh.setEnabled(not state.refreshing)
        refresh.clicked.connect(self.refresh_requested.emit)
        web = IconButton("open", "Open gebruik op claude.ai", t)
        web.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(USAGE_PAGE)))
        quit_btn = IconButton("power", "Stop Claude Usage (Ctrl+Q)", t)
        quit_btn.clicked.connect(self.quit_requested.emit)
        for b in (refresh, web, quit_btn):
            foot.addWidget(b)
        v.addLayout(foot)

        self.frame.layout().addWidget(self.content)
        self.adjustSize()

    @staticmethod
    def _toggle_autostart(check: CheckToggle, on: bool):
        try:
            autostart.set_enabled(on)
        except OSError:
            QApplication.beep()
        check.setChecked(autostart.is_enabled())

    @staticmethod
    def _section(text: str, t: dict[str, str]) -> QHBoxLayout:
        return row(label(text, 11, t["muted"], bold=True), stretch_at=1)

    @staticmethod
    def _divider(t: dict[str, str]) -> QFrame:
        line = QFrame()
        line.setFixedHeight(1)
        line.setStyleSheet(f"background: {t['divider']}; border: none;")
        return line

    @staticmethod
    def _warning(text: str, size: int) -> QLabel:
        lab = label(f"⚠ {text}", size, "#e8891e")
        lab.setWordWrap(True)
        return lab

    def show_near(self, anchor: QRect):
        """Bij de taakbalk onderaan: boven het icoon; bij een balk bovenaan (Ubuntu): eronder."""
        self.adjustSize()
        size = self.sizeHint()
        screen = QGuiApplication.screenAt(anchor.center()) or QGuiApplication.primaryScreen()
        avail = screen.availableGeometry()
        x = anchor.center().x() - size.width() // 2
        x = max(avail.left(), min(x, avail.right() - size.width()))
        if anchor.center().y() > avail.center().y():
            y = min(anchor.top(), avail.bottom()) - size.height()
        else:
            y = max(anchor.bottom(), avail.top())
        y = max(avail.top(), min(y, avail.bottom() - size.height()))
        self.move(x, y)
        self.show()
        self.raise_()
        self.activateWindow()


# ---------------------------------------------------------------- toestand en besturing

class State:
    def __init__(self, tracker: data.PlanTracker | None = None):
        self.plan = tracker or data.PlanTracker()
        self.tokens: data.TokenStats | None = None
        self.last_update: datetime | None = None
        self.refreshing = False


class Controller(QObject):
    plan_done = Signal(object)
    tokens_done = Signal(object)

    def __init__(self, app: QApplication):
        super().__init__()
        self.app = app
        self.state = State()
        self.pool = ThreadPoolExecutor(max_workers=2)
        self.pending = 0

        self.panel = Panel()
        self.panel.refresh_requested.connect(lambda: self.refresh(force=True))
        self.panel.quit_requested.connect(self.quit)

        self.tray = QSystemTrayIcon(icons.tray_icon(None))
        menu = QMenu()
        menu.addAction("Paneel openen", self.toggle_panel)
        menu.addAction("Nu verversen", lambda: self.refresh(force=True))
        menu.addSeparator()
        menu.addAction("Stop Claude Usage", self.quit)
        self.tray.setContextMenu(menu)
        self.tray.activated.connect(self._activated)
        self.tray.setToolTip("Claude-gebruik")
        self.tray.show()

        self.plan_done.connect(self._on_plan)
        self.tokens_done.connect(self._on_tokens)

        self.timer = QTimer(self, interval=TOKEN_INTERVAL * 1000, timeout=lambda: self.refresh(False))
        self.timer.start()
        # Aftelling ("over 2u 10m") actueel houden zolang het paneel open is.
        self.tick = QTimer(self, interval=30_000, timeout=self._rerender_if_visible)
        self.tick.start()
        hints = QGuiApplication.styleHints()
        if hasattr(hints, "colorSchemeChanged"):   # Qt 6.5+
            hints.colorSchemeChanged.connect(lambda _: self._rerender_if_visible())

        self._update_tray()
        self.refresh(force=False)

    # -- gegevens

    def refresh(self, force: bool):
        """Tokens altijd opnieuw tellen; de usage-API alleen als het tijd is, of bij `force`
        (de verversknop)."""
        self.state.refreshing = True
        if force or self.state.plan.due():
            self.state.plan.started()
            self.pending += 1
            self.pool.submit(lambda: self.plan_done.emit(data.fetch_plan()))
        self.pending += 1
        self.pool.submit(lambda: self.tokens_done.emit(data.scan_tokens()))
        self._rerender_if_visible()

    def _on_plan(self, result: data.PlanResult):
        self.state.plan.apply(result)
        self._done()

    def _on_tokens(self, stats: data.TokenStats):
        self.state.tokens = stats
        self._done()

    def _done(self):
        self.pending = max(0, self.pending - 1)
        self.state.refreshing = self.pending > 0
        self.state.last_update = datetime.now()
        self._update_tray()
        self._rerender_if_visible()

    # -- weergave

    def _update_tray(self):
        plan = self.state.plan
        if not plan.limits:
            self.tray.setIcon(icons.tray_icon(None))
            self.tray.setToolTip("Claude-gebruik: " + (plan.error or "laden…"))
            return
        parts = data.headline(plan.limits)
        self.tray.setIcon(icons.tray_icon(parts[0].percent))
        self.tray.setToolTip("Claude-gebruik · " + " · ".join(f"{p.label} {round(p.percent)}%" for p in parts))

    def _rerender_if_visible(self):
        if self.panel.isVisible():
            self.panel.render(self.state)

    def _activated(self, reason):
        if reason in (QSystemTrayIcon.ActivationReason.Trigger, QSystemTrayIcon.ActivationReason.DoubleClick):
            self.toggle_panel()

    def toggle_panel(self):
        # Een klik op het tray-icoon sluit eerst de popup; niet direct weer openen.
        if self.panel.isVisible() or time.monotonic() - self.panel.closed_at < 0.3:
            self.panel.close()
            return
        self.panel.render(self.state)
        geo = self.tray.geometry()
        anchor = geo if geo.isValid() and not geo.isEmpty() else QRect(QCursor.pos(), QSize(1, 1))
        self.panel.show_near(anchor)

    def quit(self):
        self.tray.hide()
        self.pool.shutdown(wait=False, cancel_futures=True)
        self.app.quit()


def run() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("Claude Usage")
    app.setQuitOnLastWindowClosed(False)
    app.setWindowIcon(icons.app_icon())
    if not QSystemTrayIcon.isSystemTrayAvailable():
        print("Geen systeemvak/tray gevonden. Op Ubuntu: zet de extensie 'Ubuntu AppIndicators' aan.",
              file=sys.stderr)
    controller = Controller(app)  # noqa: F841 (moet blijven leven)
    return app.exec()
