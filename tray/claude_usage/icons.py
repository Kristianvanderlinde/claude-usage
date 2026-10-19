"""Iconen tekenen met QPainter: het app-icoon (zelfde ontwerp als de macOS-versie) en
het tray-icoon met het sessiepercentage erin."""

from __future__ import annotations

import math

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QFont, QIcon, QImage, QLinearGradient, QPainter, QPainterPath, QPen, QPixmap

CLAUDE = QColor(217, 120, 87)
CREAM = QColor(255, 247, 237)


def level_color(pct: float) -> QColor:
    if pct >= 90:
        return QColor(220, 53, 53)
    if pct >= 75:
        return QColor(232, 140, 30)
    return CLAUDE


def app_image(size: int = 1024) -> QImage:
    img = QImage(size, size, QImage.Format.Format_ARGB32)
    img.fill(Qt.GlobalColor.transparent)
    s = size / 1024
    p = QPainter(img)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)

    tile = QRectF(100 * s, 100 * s, 824 * s, 824 * s)
    grad = QLinearGradient(tile.topLeft(), tile.bottomLeft())
    grad.setColorAt(0, QColor.fromRgbF(0.93, 0.55, 0.40))
    grad.setColorAt(1, QColor.fromRgbF(0.72, 0.33, 0.22))
    path = QPainterPath()
    path.addRoundedRect(tile, 185 * s, 185 * s)
    p.fillPath(path, grad)

    # Meter: 270° bereik, opening onderaan; Qt-hoeken in 1/16 graad, tegen de klok in vanaf 3 uur.
    cx, cy, r = 512 * s, 554 * s, 270 * s
    rect = QRectF(cx - r, cy - r, 2 * r, 2 * r)
    pen = QPen(QColor(255, 255, 255, 64), 74 * s)
    pen.setCapStyle(Qt.PenCapStyle.RoundCap)
    p.setPen(pen)
    p.drawArc(rect, 225 * 16, -270 * 16)
    pen.setColor(CREAM)
    p.setPen(pen)
    p.drawArc(rect, 225 * 16, int(-270 * 0.7 * 16))

    star = QPainterPath()
    for i in range(8):
        a = i * math.pi / 4 - math.pi / 2
        rr = (130 if i % 2 == 0 else 34) * s
        pt = QPointF(cx + math.cos(a) * rr, cy + math.sin(a) * rr)
        star.moveTo(pt) if i == 0 else star.lineTo(pt)
    star.closeSubpath()
    p.setPen(Qt.PenStyle.NoPen)
    p.fillPath(star, CREAM)
    p.end()
    return img


def app_icon() -> QIcon:
    icon = QIcon()
    for size in (16, 24, 32, 48, 64, 128, 256):
        icon.addPixmap(QPixmap.fromImage(app_image(size)))
    return icon


def tray_image(percent: float | None, size: int = 64) -> QImage:
    """Afgerond vlak in de niveaukleur met het percentage; zonder data het app-icoon."""
    if percent is None:
        return app_image(size)
    img = QImage(size, size, QImage.Format.Format_ARGB32)
    img.fill(Qt.GlobalColor.transparent)
    p = QPainter(img)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setRenderHint(QPainter.RenderHint.TextAntialiasing)

    rect = QRectF(1, 1, size - 2, size - 2)
    path = QPainterPath()
    path.addRoundedRect(rect, size * 0.22, size * 0.22)
    p.fillPath(path, level_color(percent))

    # Onderaan een dunne balk met het verbruik; op kleine formaten alleen het getal.
    small = size <= 24
    if not small:
        bar_h = size * 0.10
        track = QRectF(size * 0.16, size * 0.78, size * 0.68, bar_h)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QColor(255, 255, 255, 90))
        p.drawRoundedRect(track, bar_h / 2, bar_h / 2)
        fill = QRectF(track.x(), track.y(), max(bar_h, track.width() * min(percent, 100) / 100), bar_h)
        p.setBrush(CREAM)
        p.drawRoundedRect(fill, bar_h / 2, bar_h / 2)

    text = str(int(round(percent)))
    font = QFont()
    font.setBold(True)
    if small:
        font.setPixelSize(max(7, int(size * (0.72 if len(text) <= 2 else 0.50))))
    else:
        font.setPixelSize(int(size * (0.56 if len(text) <= 2 else 0.42)))
    p.setFont(font)
    p.setPen(CREAM)
    text_rect = QRectF(0, 0, size, size) if small else QRectF(0, size * 0.02, size, size * 0.74)
    p.drawText(text_rect, Qt.AlignmentFlag.AlignCenter, text)
    p.end()
    return img


def tray_icon(percent: float | None) -> QIcon:
    icon = QIcon()
    for size in (16, 20, 24, 32, 48, 64):
        icon.addPixmap(QPixmap.fromImage(tray_image(percent, size)))
    return icon
