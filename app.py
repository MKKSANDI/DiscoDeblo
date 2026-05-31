"""
DiscoDeblo — Discord optimization UI (PyQt5). Requires Administrator.
"""
from __future__ import annotations

import ctypes
import html
import math
import os
import subprocess
import sys
import time
import warnings
from pathlib import Path

# PyQt5/SIP emits this on QWidget subclasses; harmless until PyQt6 migration.
warnings.filterwarnings(
    "ignore",
    message=r".*sipPyTypeDict.*",
    category=DeprecationWarning,
)

from PyQt5.QtCore import (
    QAbstractAnimation,
    QEasingCurve,
    QPoint,
    QProcess,
    QPropertyAnimation,
    Qt,
    QTimer,
    pyqtSlot,
)
from PyQt5.QtGui import (
    QColor,
    QFont,
    QIcon,
    QPainter,
    QPainterPath,
    QPixmap,
    QLinearGradient,
    QRegion,
    QTextCursor,
)
from PyQt5.QtWidgets import (
    QApplication,
    QDialog,
    QGraphicsOpacityEffect,
    QHBoxLayout,
    QLabel,
    QMessageBox,
    QPushButton,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

def resource_path(name: str) -> Path:
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        return Path(sys._MEIPASS) / name
    return Path(__file__).resolve().parent / name


BASE_DIR = Path(sys.executable).resolve().parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
PS1 = BASE_DIR / "debloat_headless.ps1"
if not PS1.is_file():
    PS1 = resource_path("debloat_headless.ps1")
LOGO_PATH = resource_path("logo.png")

_SUBPROCESS_FLAGS: dict = {}
if sys.platform == "win32":
    _SUBPROCESS_FLAGS = {"creationflags": subprocess.CREATE_NO_WINDOW}

DARK_UI_STYLESHEET = """
    QWidget#card {
        background-color: rgba(0, 0, 0, 245);
        border: 1px solid rgba(255, 255, 255, 0.06);
        border-radius: 20px;
    }
    QLabel#sectionLabel {
        color: #737373;
        font-size: 11px;
        font-weight: 600;
        letter-spacing: 0.12em;
        text-transform: uppercase;
    }
    QLabel#brandTitle {
        color: #ffffff;
        font-size: 18px;
        font-weight: 700;
        letter-spacing: 0.04em;
    }
    QLabel#brandSub {
        color: #737373;
        font-size: 11px;
        font-weight: 500;
    }
    QLabel#title {
        color: #f5f5f5;
        font-size: 14px;
        font-weight: 600;
    }
    QLabel#body {
        color: #a3a3a3;
        font-size: 12px;
        line-height: 1.45;
    }
    QLabel#hint {
        color: #525252;
        font-size: 11px;
    }
    QPushButton#closeBtn {
        background: transparent;
        color: #737373;
        border: none;
        font-size: 20px;
        border-radius: 8px;
        min-width: 36px;
        min-height: 32px;
    }
    QPushButton#closeBtn:hover {
        background: rgba(255, 255, 255, 0.06);
        color: #fafafa;
    }
    QPushButton#primaryBtn {
        background-color: rgba(10, 10, 10, 250);
        color: #f0f0f0;
        border: 1px solid rgba(255, 255, 255, 0.1);
        border-radius: 11px;
        font-size: 12px;
        font-weight: 600;
        padding: 10px 14px;
    }
    QPushButton#primaryBtn:hover {
        background-color: rgba(26, 26, 26, 255);
        border-color: rgba(255, 255, 255, 0.14);
    }
    QPushButton#dangerBtn {
        background-color: rgba(26, 18, 18, 240);
        color: #e8b4b4;
        border: 1px solid rgba(239, 68, 68, 0.25);
        border-radius: 11px;
        font-size: 12px;
        font-weight: 600;
        padding: 10px 14px;
    }
    QPushButton#dangerBtn:hover {
        background-color: rgba(48, 22, 22, 255);
        border-color: rgba(239, 68, 68, 0.4);
    }
    QPushButton#ghostBtn {
        background-color: transparent;
        color: #888888;
        border: 1px solid rgba(255, 255, 255, 0.08);
        border-radius: 11px;
        font-size: 12px;
        padding: 10px 14px;
    }
    QPushButton#ghostBtn:hover {
        background-color: rgba(255, 255, 255, 0.05);
        color: #bdbdbd;
    }
    QTextEdit#log {
        background-color: rgba(0, 0, 0, 230);
        color: #c4c4c4;
        border: 1px solid rgba(255, 255, 255, 0.06);
        border-radius: 14px;
        padding: 12px;
        selection-background-color: #404040;
    }
    QPushButton#optimizeBtn {
        background: qlineargradient(x1:0, y1:0, x2:1, y2:0,
            stop:0 #0a0a0a, stop:1 #1a1a1a);
        color: #ffffff;
        border: 1px solid rgba(255, 255, 255, 0.12);
        border-radius: 14px;
        font-size: 13px;
        font-weight: 700;
        letter-spacing: 0.06em;
    }
    QPushButton#optimizeBtn:hover {
        background: qlineargradient(x1:0, y1:0, x2:1, y2:0,
            stop:0 #1a1a1a, stop:1 #2a2a2a);
        border-color: rgba(255, 255, 255, 0.18);
    }
    QPushButton#optimizeBtn:pressed {
        background: #0a0a0a;
    }
    QPushButton#optimizeBtn:disabled {
        color: #404040;
        border-color: rgba(255, 255, 255, 0.04);
        background: #000000;
    }
"""


def attach_press_flicker(btn: QPushButton) -> None:
    """Subtle opacity pulse on press."""

    def on_pressed() -> None:
        eff = btn.graphicsEffect()
        if eff is None or not isinstance(eff, QGraphicsOpacityEffect):
            eff = QGraphicsOpacityEffect(btn)
            btn.setGraphicsEffect(eff)
        anim = QPropertyAnimation(eff, b"opacity", btn)
        anim.setDuration(160)
        anim.setEasingCurve(QEasingCurve.OutCubic)
        anim.setKeyValueAt(0.0, 1.0)
        anim.setKeyValueAt(0.35, 0.78)
        anim.setKeyValueAt(1.0, 1.0)
        anim.start(QAbstractAnimation.DeleteWhenStopped)

    btn.pressed.connect(on_pressed)


def load_brand_pixmap(size: int = 40) -> QPixmap:
    if LOGO_PATH.is_file():
        pm = QPixmap(str(LOGO_PATH))
        if not pm.isNull():
            return pm.scaled(
                size, size, Qt.KeepAspectRatio, Qt.SmoothTransformation
            )
    pm = QPixmap(size, size)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    g = QLinearGradient(0, 0, float(size), float(size))
    g.setColorAt(0.0, QColor("#262626"))
    g.setColorAt(1.0, QColor("#0a0a0a"))
    p.setBrush(g)
    p.setPen(Qt.NoPen)
    r = size // 5
    p.drawRoundedRect(0, 0, size, size, r, r)
    p.setPen(QColor("#ffffff"))
    p.setFont(QFont("Segoe UI", max(10, int(size * 0.42)), QFont.Bold))
    p.drawText(pm.rect(), Qt.AlignCenter, "D")
    p.end()
    return pm


class DraggableTitleBar(QWidget):
    """Full-width header: logo/labels use pass-through clicks; drag hits this widget."""

    def __init__(self, frame: QWidget, close_btn: QPushButton) -> None:
        super().__init__()
        self._frame = frame
        self._close = close_btn
        self._drag: QPoint | None = None

    def mousePressEvent(self, event) -> None:
        if event.button() == Qt.LeftButton:
            pos = event.pos()
            if self._close_under(pos):
                super().mousePressEvent(event)
                return
            self._drag = event.globalPos() - self._frame.frameGeometry().topLeft()
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event) -> None:
        if self._drag is not None and event.buttons() & Qt.LeftButton:
            self._frame.move(event.globalPos() - self._drag)
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event) -> None:
        if event.button() == Qt.LeftButton:
            self._drag = None
        super().mouseReleaseEvent(event)

    def _close_under(self, pos: QPoint) -> bool:
        c = self.childAt(pos)
        if c is None:
            return False
        return c is self._close or self._close.isAncestorOf(c)


def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def relaunch_elevated() -> None:
    exe = sys.executable
    if getattr(sys, "frozen", False):
        params = ""
    else:
        script = str(Path(__file__).resolve())
        params = f'"{script}"'
    ret = ctypes.windll.shell32.ShellExecuteW(None, "runas", exe, params, str(BASE_DIR), 1)
    if int(ret) <= 32:
        sys.exit(1)
    sys.exit(0)


def _version_tuple(name: str) -> tuple[int, ...]:
    tail = name[4:] if name.startswith("app-") else name
    out: list[int] = []
    for part in tail.replace("_", ".").split("."):
        try:
            out.append(int(part))
        except ValueError:
            out.append(0)
    return tuple(out)


def get_discord_exe_path() -> Path | None:
    base = Path(os.environ.get("LOCALAPPDATA", "")) / "Discord"
    if not base.is_dir():
        return None
    best_dir: Path | None = None
    best_ver: tuple[int, ...] | None = None
    for child in base.iterdir():
        if not child.is_dir() or not child.name.startswith("app-"):
            continue
        vt = _version_tuple(child.name)
        if best_ver is None or vt > best_ver:
            best_ver = vt
            best_dir = child
    if best_dir:
        exe = best_dir / "Discord.exe"
        if exe.is_file():
            return exe
    return None


def _tasklist_has_process(image_name: str) -> bool:
    try:
        r = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {image_name}", "/NH"],
            capture_output=True,
            text=True,
            timeout=15,
            **_SUBPROCESS_FLAGS,
        )
        out = (r.stdout or "").lower()
        if "no tasks" in out:
            return False
        needle = image_name.lower()
        for line in (r.stdout or "").splitlines():
            if line.strip().lower().startswith(needle):
                return True
        return False
    except Exception:
        return False


def is_discord_running() -> bool:
    return _tasklist_has_process("Discord.exe")


def kill_discord_processes() -> None:
    subprocess.run(
        ["taskkill", "/IM", "Discord.exe", "/F", "/T"],
        capture_output=True,
        timeout=45,
        **_SUBPROCESS_FLAGS,
    )
    # Discord Update.exe lives under %LOCALAPPDATA%\Discord — avoid killing unrelated Update.exe.
    ps = (
        "Get-Process -Name Update -EA SilentlyContinue | "
        "Where-Object { $_.Path -like '*\\Discord\\*' } | "
        "Stop-Process -Force -EA SilentlyContinue"
    )
    subprocess.run(
        ["powershell.exe", "-NoProfile", "-Command", ps],
        capture_output=True,
        timeout=30,
        **_SUBPROCESS_FLAGS,
    )


def wait_for_discord_exit(timeout_sec: float = 8.0) -> bool:
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        if not is_discord_running():
            return True
        time.sleep(0.35)
    return not is_discord_running()


def start_discord() -> bool:
    exe = get_discord_exe_path()
    if not exe:
        return False
    try:
        subprocess.Popen([str(exe)], cwd=str(exe.parent), close_fds=True)
        return True
    except Exception:
        return False


class DiscordBlockingDialog(QDialog):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._radius = 18
        self._grad_t = 0.0
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.Dialog)
        self.setAttribute(Qt.WA_TranslucentBackground, True)
        self.setModal(True)
        self.setFixedSize(432, 280)

        self._root = QWidget(self)
        self._root.setObjectName("card")

        close_btn = QPushButton("×")
        close_btn.setObjectName("closeBtn")
        close_btn.clicked.connect(self.reject)
        attach_press_flicker(close_btn)

        title_bar = DraggableTitleBar(self, close_btn)
        title_bar.setFixedHeight(44)
        tb_layout = QHBoxLayout(title_bar)
        tb_layout.setContentsMargins(0, 0, 0, 0)
        tb_layout.setSpacing(10)
        ttl = QLabel("Discord is running")
        ttl.setObjectName("title")
        ttl.setAttribute(Qt.WA_TransparentForMouseEvents, True)
        tb_layout.addWidget(ttl)
        tb_layout.addStretch(1)
        tb_layout.addWidget(close_btn, 0, Qt.AlignTop)

        body = QLabel(
            "Close Discord before optimizing. You can end it from here, "
            "or close it yourself and continue."
        )
        body.setObjectName("body")
        body.setWordWrap(True)

        self._hint = QLabel("")
        self._hint.setObjectName("hint")
        self._hint.setWordWrap(True)

        self._kill_btn = QPushButton("Kill Discord")
        self._kill_btn.setObjectName("dangerBtn")
        self._kill_btn.setMinimumHeight(42)
        self._kill_btn.clicked.connect(self._on_kill)
        attach_press_flicker(self._kill_btn)

        cont_btn = QPushButton("I closed it")
        cont_btn.setObjectName("primaryBtn")
        cont_btn.setMinimumHeight(42)
        cont_btn.clicked.connect(self._on_continue)
        attach_press_flicker(cont_btn)

        btn_row1 = QHBoxLayout()
        btn_row1.setSpacing(10)
        btn_row1.addWidget(self._kill_btn, 1)
        btn_row1.addWidget(cont_btn, 1)

        cancel_btn = QPushButton("Cancel")
        cancel_btn.setObjectName("ghostBtn")
        cancel_btn.setMinimumHeight(40)
        cancel_btn.clicked.connect(self.reject)
        attach_press_flicker(cancel_btn)

        outer = QVBoxLayout(self._root)
        outer.setContentsMargins(22, 18, 22, 20)
        outer.setSpacing(14)
        outer.addWidget(title_bar)
        outer.addWidget(body)
        outer.addWidget(self._hint)
        outer.addStretch(1)
        outer.addLayout(btn_row1)
        outer.addWidget(cancel_btn)

        self.setStyleSheet(DARK_UI_STYLESHEET)

        self._pulse = QTimer(self)
        self._pulse.timeout.connect(self._tick_bg)
        self._pulse.start(80)

    def _tick_bg(self) -> None:
        self._grad_t += 0.018
        self.update()

    def paintEvent(self, event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        path = QPainterPath()
        path.addRoundedRect(
            0, 0, self.width(), self.height(), self._radius, self._radius
        )
        p.setClipPath(path)
        t = self._grad_t
        # Pure black / monochrome: subtle luminance drift only (no color tint).
        w, h = self.width(), self.height()
        mid = int(8 + 6 * math.sin(t * 0.55))
        edge = int(3 + 2 * math.cos(t * 0.4))
        g = QLinearGradient(0, 0, w, h)
        g.setColorAt(0.0, QColor(edge, edge, edge))
        g.setColorAt(0.45, QColor(mid, mid, mid))
        g.setColorAt(1.0, QColor(0, 0, 0))
        p.fillPath(path, g)
        p.setCompositionMode(QPainter.CompositionMode_Plus)
        cx = w * 0.35 + math.sin(t * 0.7) * w * 0.1
        cy = h * 0.4 + math.cos(t * 0.55) * h * 0.08
        sheen = QLinearGradient(cx, cy - 40, cx + w * 0.5, cy + h * 0.35)
        sheen.setColorAt(0.0, QColor(255, 255, 255, 10))
        sheen.setColorAt(0.55, QColor(255, 255, 255, 4))
        sheen.setColorAt(1.0, QColor(255, 255, 255, 0))
        p.fillPath(path, sheen)
        p.end()
        super().paintEvent(event)

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        m = 8
        self._root.setGeometry(m, m, self.width() - 2 * m, self.height() - 2 * m)
        path = QPainterPath()
        path.addRoundedRect(0, 0, self.width(), self.height(), self._radius, self._radius)
        self.setMask(QRegion(path.toFillPolygon().toPolygon()))

    def showEvent(self, event) -> None:
        super().showEvent(event)
        if self.parent() and hasattr(self.parent(), "geometry"):
            pg = self.parent().geometry()
            self.move(
                pg.center().x() - self.width() // 2,
                pg.center().y() - self.height() // 2,
            )

    def _on_kill(self) -> None:
        self._kill_btn.setEnabled(False)
        self._hint.setText("Closing Discord...")
        QApplication.processEvents()
        kill_discord_processes()
        if wait_for_discord_exit():
            self.done(QDialog.Accepted)
            return
        self._kill_btn.setEnabled(True)
        self._hint.setText(
            "Could not end all Discord processes. Try again or close manually."
        )

    def _on_continue(self) -> None:
        if wait_for_discord_exit(0.5):
            self.done(QDialog.Accepted)
        else:
            self._hint.setText(
                "Discord is still running — close it or use Kill Discord."
            )


def confirm_non_destructive_operation(parent: QWidget, title: str, detail: str) -> bool:
    """Return True only when the user explicitly agrees to an optional high-impact action."""
    message = (
        f"{detail}\n\n"
        f"Do you want to continue with '{title}'?"
    )
    reply = QMessageBox.question(
        parent,
        f"Confirm {title}",
        message,
        QMessageBox.Yes | QMessageBox.No,
        QMessageBox.No,
    )
    return reply == QMessageBox.Yes


class RoundedWindow(QWidget):
    def __init__(self) -> None:
        super().__init__()
        self._radius = 22
        self._grad_t = 0.0
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.Window)
        self.setAttribute(Qt.WA_TranslucentBackground, True)
        self.setWindowIcon(QIcon(str(LOGO_PATH)))
        self.resize(780, 560)
        self.setMinimumSize(680, 500)

        root = QWidget(self)
        root.setObjectName("card")
        root.setGeometry(10, 10, self.width() - 20, self.height() - 20)

        close_btn = QPushButton("×")
        close_btn.setObjectName("closeBtn")
        close_btn.clicked.connect(self.close)
        attach_press_flicker(close_btn)

        title_bar = DraggableTitleBar(self, close_btn)
        title_bar.setFixedHeight(52)
        tb = QHBoxLayout(title_bar)
        tb.setContentsMargins(0, 0, 4, 0)
        tb.setSpacing(12)

        logo = QLabel()
        logo.setPixmap(load_brand_pixmap(42))
        logo.setFixedSize(42, 42)
        logo.setAttribute(Qt.WA_TransparentForMouseEvents, True)

        brand_col = QVBoxLayout()
        brand_col.setSpacing(2)
        brand_col.setContentsMargins(0, 4, 0, 0)
        brand_title = QLabel("DiscoDeblo")
        brand_title.setObjectName("brandTitle")
        brand_title.setAttribute(Qt.WA_TransparentForMouseEvents, True)
        brand_sub = QLabel("Mod-aware Discord performance cleanup")
        brand_sub.setObjectName("brandSub")
        brand_sub.setAttribute(Qt.WA_TransparentForMouseEvents, True)
        brand_col.addWidget(brand_title)
        brand_col.addWidget(brand_sub)

        tb.addWidget(logo, 0, Qt.AlignVCenter)
        tb.addLayout(brand_col)
        tb.addStretch(1)
        tb.addWidget(close_btn, 0, Qt.AlignTop)

        section = QLabel("Optimization log")
        section.setObjectName("sectionLabel")

        self.status = QLabel("Balanced mode protects account data, updater files, and client mods.")
        self.status.setObjectName("body")
        self.status.setWordWrap(True)

        self.log = QTextEdit()
        self.log.setReadOnly(True)
        self.log.setObjectName("log")
        self.log.document().setMaximumBlockCount(1000)
        self.log.setLineWrapMode(QTextEdit.WidgetWidth)
        mono = QFont("Cascadia Mono", 10)
        if not mono.exactMatch():
            mono = QFont("Consolas", 10)
        self.log.setFont(mono)

        self.optimize_btn = QPushButton("OPTIMIZE DISCORD")
        self.optimize_btn.setObjectName("optimizeBtn")
        self.optimize_btn.setMinimumHeight(48)
        self.optimize_btn.setCursor(Qt.PointingHandCursor)
        attach_press_flicker(self.optimize_btn)

        self.lean_btn = QPushButton("LEAN MODS")
        self.lean_btn.setObjectName("dangerBtn")
        self.lean_btn.setMinimumHeight(42)
        self.lean_btn.setCursor(Qt.PointingHandCursor)
        attach_press_flicker(self.lean_btn)

        self.restore_btn = QPushButton("RESTORE MODS")
        self.restore_btn.setObjectName("ghostBtn")
        self.restore_btn.setMinimumHeight(42)
        self.restore_btn.setCursor(Qt.PointingHandCursor)
        attach_press_flicker(self.restore_btn)

        action_row = QHBoxLayout()
        action_row.setSpacing(10)
        action_row.addWidget(self.lean_btn, 1)
        action_row.addWidget(self.restore_btn, 1)

        self._drag_pos = None  # unused; drag via DraggableTitleBar
        self.process: QProcess | None = None
        self._root = root
        self._relaunch_discord_after_run = False
        self._buttons = [self.optimize_btn, self.lean_btn, self.restore_btn]

        outer = QVBoxLayout(root)
        outer.setContentsMargins(22, 10, 22, 20)
        outer.setSpacing(12)
        outer.addWidget(title_bar)
        outer.addWidget(section)
        outer.addWidget(self.status)
        outer.addWidget(self.log, 1)
        outer.addWidget(self.optimize_btn)
        outer.addLayout(action_row)

        self.optimize_btn.clicked.connect(self.run_optimize)
        self.lean_btn.clicked.connect(self.run_lean_mods)
        self.restore_btn.clicked.connect(self.run_restore_mods)

        self.setStyleSheet(DARK_UI_STYLESHEET)

        self._pulse = QTimer(self)
        self._pulse.timeout.connect(self._tick_bg)
        self._pulse.start(80)

    def _tick_bg(self) -> None:
        self._grad_t += 0.015
        self.update()

    def paintEvent(self, event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        path = QPainterPath()
        path.addRoundedRect(
            0, 0, self.width(), self.height(), self._radius, self._radius
        )
        p.setClipPath(path)

        t = self._grad_t
        w, h = self.width(), self.height()
        v1 = int(5 + 5 * math.sin(t * 0.5))
        v2 = int(10 + 6 * math.cos(t * 0.42))
        v3 = int(2 + 2 * math.sin(t * 0.65 + 1.1))
        g = QLinearGradient(0, 0, w, h)
        g.setColorAt(0.0, QColor(0, 0, 0))
        g.setColorAt(0.32, QColor(v1, v1, v1))
        g.setColorAt(0.58, QColor(v2, v2, v2))
        g.setColorAt(0.82, QColor(v3, v3, v3))
        g.setColorAt(1.0, QColor(0, 0, 0))
        p.fillPath(path, g)

        p.setCompositionMode(QPainter.CompositionMode_Plus)
        ax = w * 0.15 + math.sin(t * 0.52) * w * 0.12
        ay = h * 0.12 + math.cos(t * 0.38) * 35
        sheen = QLinearGradient(ax, ay, ax + w * 0.85, ay + h * 0.9)
        sheen.setColorAt(0.0, QColor(255, 255, 255, 14))
        sheen.setColorAt(0.4, QColor(255, 255, 255, 5))
        sheen.setColorAt(1.0, QColor(255, 255, 255, 0))
        p.fillPath(path, sheen)

        p.setCompositionMode(QPainter.CompositionMode_Plus)
        bx = w * 0.72 + math.cos(t * 0.48) * 50
        by = h * 0.62 + math.sin(t * 0.33) * 45
        sheen2 = QLinearGradient(bx, by, bx - w * 0.45, by - h * 0.35)
        sheen2.setColorAt(0.0, QColor(255, 255, 255, 8))
        sheen2.setColorAt(1.0, QColor(255, 255, 255, 0))
        p.fillPath(path, sheen2)

        p.end()
        super().paintEvent(event)

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        m = 10
        self._root.setGeometry(m, m, self.width() - 2 * m, self.height() - 2 * m)
        path = QPainterPath()
        path.addRoundedRect(0, 0, self.width(), self.height(), self._radius, self._radius)
        self.setMask(QRegion(path.toFillPolygon().toPolygon()))

    @pyqtSlot()
    def run_optimize(self) -> None:
        self._run_script(
            [
                "-Profile",
                "Balanced",
                "-WarmLaunchCache",
            ],
            "Running Balanced optimization. Discord will be restarted if it was open.",
            (
                "[INFO] Starting Balanced optimize (mod-aware cache/settings/locales; "
                "updater/app.asar/modules/shortcuts protected)..."
            ),
        )

    @pyqtSlot()
    def run_lean_mods(self) -> None:
        if not confirm_non_destructive_operation(
            self,
            "Lean Mods",
            (
                "Lean Mods disables non-core Vencord and BetterDiscord plugin/theme entries "
                "after creating a backup in the DiscordBackup folder."
            ),
        ):
            return
        self._run_script(
            [
                "-Profile",
                "Balanced",
                "-WarmLaunchCache",
                "-LeanMods",
            ],
            "Running Lean Mods. Vencord/BetterDiscord settings are backed up before changes.",
            (
                "[WARN] Starting Lean Mods: disables non-core Vencord plugins/themes "
                "and BetterDiscord plugin/theme files after backup."
            ),
        )

    @pyqtSlot()
    def run_restore_mods(self) -> None:
        if not confirm_non_destructive_operation(
            self,
            "Restore Mods",
            "Restore will re-apply the latest Lean Mods backup for mod files.",
        ):
            return
        self._run_script(
            [
                "-RestoreMods",
            ],
            "Restoring the most recent Lean Mods backup.",
            "[INFO] Restoring Vencord/BetterDiscord settings from latest Lean Mods backup...",
        )

    def _set_buttons_enabled(self, enabled: bool) -> None:
        for button in self._buttons:
            button.setEnabled(enabled)

    def _run_script(self, extra_args: list[str], status_text: str, intro_line: str) -> None:
        if not PS1.is_file():
            self.append_log(f"[ERR] Missing script: {PS1}")
            return
        if self.process is not None and self.process.state() != QProcess.NotRunning:
            return

        discord_was_running = is_discord_running()
        self._relaunch_discord_after_run = False

        if discord_was_running:
            dlg = DiscordBlockingDialog(self)
            if dlg.exec_() != QDialog.Accepted:
                return
            if is_discord_running():
                self.append_log("[ERR] Discord is still running. Close it and try again.")
                return

        self._relaunch_discord_after_run = discord_was_running

        self.log.clear()
        self._set_buttons_enabled(False)
        self.status.setText(status_text)
        self.append_log(intro_line)

        self.process = QProcess(self)
        self.process.setProcessChannelMode(QProcess.MergedChannels)
        self.process.setProgram("powershell.exe")
        self.process.setArguments(
            [
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(PS1),
            ]
            + extra_args
        )
        self.process.setWorkingDirectory(str(BASE_DIR))
        self.process.readyReadStandardOutput.connect(self._read_output)
        self.process.finished.connect(self._on_finished)
        self.process.start()

    def append_log(self, line: str) -> None:
        colors = {
            "OK": "#6ee7b7",
            "INFO": "#93c5fd",
            "WARN": "#fbbf24",
            "ERR": "#f87171",
        }
        escaped = html.escape(line)
        level = ""
        if line.startswith("[") and "]" in line[:8]:
            level = line[1:line.find("]")]
        color = colors.get(level, "#c4c4c4")
        if level:
            prefix = html.escape(f"[{level}]")
            rest = html.escape(line[len(prefix):])
            html_line = (
                f'<span style="color:{color}; font-weight:700;">{prefix}</span>'
                f'<span style="color:#d4d4d4;">{rest}</span>'
            )
        else:
            html_line = f'<span style="color:{color};">{escaped}</span>'
        self.log.append(html_line)
        self.log.moveCursor(QTextCursor.End)

    def _read_output(self) -> None:
        if not self.process:
            return
        data = self.process.readAllStandardOutput().data().decode("utf-8", errors="replace")
        if data.strip():
            for line in data.rstrip("\r\n").splitlines():
                if line.strip():
                    self.append_log(line)

    @pyqtSlot(int, QProcess.ExitStatus)
    def _on_finished(self, code: int, _status: QProcess.ExitStatus) -> None:
        self._set_buttons_enabled(True)
        self.append_log(f"[INFO] Process exited with code {code}")
        if (
            code == 0
            and self._relaunch_discord_after_run
            and not is_discord_running()
        ):
            if start_discord():
                self.append_log("[OK] Started Discord again.")
            else:
                self.append_log("[WARN] Could not start Discord — open it from the Start menu.")
        self.status.setText("Ready. Balanced mode protects account data, updater files, and client mods.")
        self._relaunch_discord_after_run = False


def main() -> None:
    if sys.platform != "win32":
        print("This tool is for Windows only.", file=sys.stderr)
        sys.exit(1)
    if not is_admin():
        relaunch_elevated()

    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    app.setWindowIcon(QIcon(str(LOGO_PATH)))

    w = RoundedWindow()
    w.show()

    if not PS1.is_file():
        QTimer.singleShot(
            0,
            lambda: w.append_log(
                f"[WARN] Place debloat_headless.ps1 next to app.py (expected {PS1})"
            ),
        )

    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
