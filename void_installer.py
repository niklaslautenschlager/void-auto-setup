#!/usr/bin/env python3
"""void-installer — Void Linux post-install configurator (TUI).

Modelled after archinstall.  Run as root:
    sudo python3 void_installer.py
"""

import curses
import os
import subprocess
import sys
import textwrap
import time
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

# ── version / paths ───────────────────────────────────────────────────────────
VERSION          = "2026-03-10"
LOG_FILE         = "/var/log/void-installer.log"
SCRIPT_DIR       = os.path.dirname(os.path.realpath(__file__))
WALLPAPER_REPO   = os.path.join(SCRIPT_DIR, "wallpaper", "sample.jpg")
WALLPAPER_SYS    = "/usr/share/backgrounds/void-auto-setup/sample.jpg"

# ── ASCII art ─────────────────────────────────────────────────────────────────
# Prefer figlet at runtime; fall back to hardcoded block art.
_FALLBACK_ART: List[str] = [
    r"██╗   ██╗  ██████╗  ██╗██████╗ ",
    r"██║   ██║ ██╔═══██╗ ██║██╔══██╗",
    r"██║   ██║ ██║   ██║ ██║██║  ██║",
    r"╚██╗ ██╔╝ ██║   ██║ ██║██║  ██║",
    r" ╚████╔╝  ╚██████╔╝ ██║██████╔╝",
    r"  ╚═══╝    ╚═════╝  ╚═╝╚═════╝ ",
    r"",
    r" ██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗     ███████╗██████╗ ",
    r" ██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║     ██╔════╝██╔══██╗",
    r" ██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║     █████╗  ██████╔╝",
    r" ██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║     ██╔══╝  ██╔══██╗",
    r" ██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗███████╗██║  ██║",
    r" ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝  ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝",
]

def _build_title_art() -> List[str]:
    """Return figlet art for 'VOID INSTALLER' if figlet is available, else fallback."""
    import shutil
    if shutil.which("figlet"):
        try:
            # Try big font first, then default
            for font_args in (["-f", "big"], ["-f", "banner"], []):
                r = subprocess.run(
                    ["figlet"] + font_args + ["VOID", "INSTALLER"],
                    capture_output=True, text=True, timeout=3)
                if r.returncode == 0 and r.stdout.strip():
                    return r.stdout.rstrip("\n").splitlines()
        except Exception:
            pass
    try:
        import pyfiglet
        art = pyfiglet.figlet_format("VOID\nINSTALLER", font="big")
        return art.rstrip("\n").splitlines()
    except Exception:
        pass
    return _FALLBACK_ART

TITLE_ART: List[str] = _build_title_art()

# ── config dataclass ──────────────────────────────────────────────────────────
@dataclass
class Config:
    username:          str  = ""
    seat_stack:        str  = "elogind"
    desktop:           str  = "i3"
    login_manager:     str  = "sddm"
    browser:           str  = "firefox"
    gpu:               str  = "auto"
    launcher:          str  = "rofi"
    file_manager:      str  = "nemo"
    wallpaper_manager: str  = "none"
    wallpaper_backend: str  = "none"
    fonts:             bool = True
    flatpak:           bool = True
    fastfetch:         bool = True
    dev_tools:         bool = False
    gaming:            bool = True

# ── curses colour pairs ───────────────────────────────────────────────────────
CP_NORMAL  = 1   # white on default bg
CP_GREEN   = 2   # bright green on default bg
CP_HILIGHT = 3   # black on green  (selected row)
CP_WARN    = 4   # yellow
CP_ERR     = 5   # red
CP_DIM     = 6   # grey / dark

def _init_colors() -> None:
    curses.start_color()
    curses.use_default_colors()
    green = curses.COLOR_GREEN
    if curses.can_change_color() and curses.COLORS >= 256:
        curses.init_color(10,
                          int(70  * 1000 / 255),
                          int(185 * 1000 / 255),
                          int(54  * 1000 / 255))
        green = 10
    curses.init_pair(CP_NORMAL,  curses.COLOR_WHITE,  -1)
    curses.init_pair(CP_GREEN,   green,                -1)
    curses.init_pair(CP_HILIGHT, curses.COLOR_BLACK,   green)
    curses.init_pair(CP_WARN,    curses.COLOR_YELLOW,  -1)
    curses.init_pair(CP_ERR,     curses.COLOR_RED,     -1)
    dim = 8 if curses.COLORS >= 256 else curses.COLOR_WHITE
    curses.init_pair(CP_DIM,     dim,                  -1)

def _safe_addstr(win, y: int, x: int, text: str, attr: int = 0) -> None:
    h, w = win.getmaxyx()
    if y < 0 or y >= h or x < 0 or x >= w:
        return
    clip = w - x - 1
    if clip <= 0:
        return
    try:
        win.addstr(y, x, text[:clip], attr)
    except curses.error:
        pass

def draw_header(win) -> int:
    """Draw ASCII art title; return next free row index."""
    _, w = win.getmaxyx()
    attr = curses.color_pair(CP_GREEN) | curses.A_BOLD
    for i, line in enumerate(TITLE_ART):
        x = max(0, (w - len(line)) // 2)
        _safe_addstr(win, i, x, line, attr)
    return len(TITLE_ART) + 1

# ── generic menu widgets ──────────────────────────────────────────────────────

def menu_select(win, title: str, options: List[str], current: int = 0) -> int:
    """Arrow-key list. Returns chosen index or -1 on Esc/q."""
    curses.curs_set(0)
    idx = max(0, min(current, len(options) - 1))
    while True:
        win.clear()
        h, w = win.getmaxyx()
        header_h = draw_header(win)
        _safe_addstr(win, header_h, 2, title,
                     curses.color_pair(CP_GREEN) | curses.A_BOLD)
        base = header_h + 2
        for i, opt in enumerate(options):
            r = base + i
            if r >= h - 1:
                break
            if i == idx:
                attr = curses.color_pair(CP_HILIGHT) | curses.A_BOLD
                _safe_addstr(win, r, 4, f"  {opt:<{w - 9}}  ", attr)
            else:
                _safe_addstr(win, r, 4, f"  {opt}",
                             curses.color_pair(CP_NORMAL))
        footer = "  ↑/k  ↓/j  navigate    Enter  select    Esc  back  "
        _safe_addstr(win, h - 1, 0, footer[:w - 1], curses.color_pair(CP_DIM))
        win.refresh()
        key = win.getch()
        if   key in (curses.KEY_UP,    ord('k')): idx = (idx - 1) % len(options)
        elif key in (curses.KEY_DOWN,  ord('j')): idx = (idx + 1) % len(options)
        elif key in (curses.KEY_ENTER, ord('\n'), ord('\r')): return idx
        elif key in (27, ord('q')): return -1


def text_prompt(win, prompt: str, default: str = "") -> str:
    """Single-line text input. Returns entered string (or default)."""
    curses.curs_set(1)
    h, w = win.getmaxyx()
    win.clear()
    draw_header(win)
    row = h // 2
    _safe_addstr(win, row,     2, prompt,
                 curses.color_pair(CP_GREEN) | curses.A_BOLD)
    if default:
        _safe_addstr(win, row + 1, 2, f"(leave blank to keep: {default})",
                     curses.color_pair(CP_DIM))
    _safe_addstr(win, row + 3, 2, "> ", curses.color_pair(CP_NORMAL))
    win.refresh()
    curses.echo()
    buf = win.getstr(row + 3, 4, 64).decode("utf-8", errors="replace").strip()
    curses.noecho()
    curses.curs_set(0)
    return buf or default


def yes_no_prompt(win, question: str, default: bool = True) -> bool:
    idx = menu_select(win, question, ["Yes", "No"], 0 if default else 1)
    return (idx == 0) if idx != -1 else default

# ── option tables (id, display label) ────────────────────────────────────────
DESKTOP_OPTS: List[Tuple[str, str]] = [
    ("i3",           "i3             — tiling WM (X11, default)"),
    ("plasma",       "KDE Plasma     — full DE (X11/Wayland)"),
    ("river",        "river          — tiling WM (Wayland)"),
    ("dwm",          "dwm            — minimal suckless WM (X11)"),
    ("niri",         "niri           — scrollable tiling (Wayland)"),
    ("hyprland",     "Hyprland       — eye candy (Wayland, EXPERIMENTAL)"),
    ("sway",         "sway           — i3-compatible (Wayland)"),
    ("swayfx",       "SwayFX         — sway with effects (Wayland)"),
    ("awesome",      "awesome        — configurable WM (X11)"),
    ("herbstluftwm", "herbstluftwm   — manual tiling (X11)"),
    ("xfce",         "XFCE           — lightweight DE (X11)"),
    ("gnome",        "GNOME          — full DE"),
    ("mate",         "MATE           — classic DE (X11)"),
]
SEAT_OPTS: List[Tuple[str, str]] = [
    ("elogind", "elogind  — recommended, KDE/SDDM compatible"),
    ("seatd",   "seatd    — lean, Wayland-native"),
]
LM_OPTS: List[Tuple[str, str]] = [
    ("sddm",    "SDDM       — recommended (default)"),
    ("lightdm", "LightDM    — GTK greeter"),
    ("greetd",  "greetd     — + tuigreet"),
    ("ly",      "Ly         — TUI, lightweight"),
    ("none",    "None       — startx / TTY"),
]
BROWSER_OPTS: List[Tuple[str, str]] = [
    ("firefox",       "Firefox (default)"),
    ("chromium",      "Chromium"),
    ("brave-browser", "Brave"),
    ("librewolf",     "LibreWolf"),
]
GPU_OPTS: List[Tuple[str, str]] = [
    ("auto",   "Auto-detect (default)"),
    ("nvidia", "NVIDIA — proprietary driver"),
    ("amd",    "AMD    — Mesa + Vulkan"),
    ("intel",  "Intel  — Mesa"),
]
LAUNCHER_X11: List[Tuple[str, str]] = [
    ("rofi",  "rofi  (recommended)"),
    ("dmenu", "dmenu"),
    ("none",  "None"),
]
LAUNCHER_WAY: List[Tuple[str, str]] = [
    ("wofi",   "wofi   (recommended)"),
    ("fuzzel", "fuzzel"),
    ("none",   "None"),
]
FM_KDE: List[Tuple[str, str]] = [
    ("dolphin", "dolphin (recommended for KDE)"),
    ("thunar",  "thunar"), ("nemo", "nemo"), ("pcmanfm", "pcmanfm"), ("none", "None"),
]
FM_WAY: List[Tuple[str, str]] = [
    ("thunar",  "thunar  (recommended)"),
    ("nemo", "nemo"), ("pcmanfm", "pcmanfm"), ("dolphin", "dolphin"), ("none", "None"),
]
FM_X11: List[Tuple[str, str]] = [
    ("nemo",    "nemo    (recommended)"),
    ("thunar", "thunar"), ("pcmanfm", "pcmanfm"), ("dolphin", "dolphin"), ("none", "None"),
]
WALLMGR_WAY: List[Tuple[str, str]] = [
    ("none",     "None"),
    ("azote",    "azote"),
    ("waypaper", "waypaper (via pipx)"),
]
WALLMGR_X11: List[Tuple[str, str]] = [
    ("none",     "None"),
    ("nitrogen", "nitrogen"),
    ("waypaper", "waypaper (via pipx)"),
]
WAYBACK_WAY: List[Tuple[str, str]] = [
    ("swaybg",    "swaybg (stable default)"),
    ("swww",      "swww"),
    ("hyprpaper", "hyprpaper"),
]
WAYBACK_X11: List[Tuple[str, str]] = [
    ("feh",        "feh (default)"),
    ("xwallpaper", "xwallpaper"),
]

def _is_wayland(desktop: str) -> bool:
    return desktop in {"river", "niri", "hyprland", "sway", "swayfx"}

def _pick(win, title: str, opts: List[Tuple[str, str]], current_id: str) -> str:
    labels = [lbl for _, lbl in opts]
    ids    = [id_ for id_, _ in opts]
    cur    = next((i for i, x in enumerate(ids) if x == current_id), 0)
    r = menu_select(win, title, labels, cur)
    return ids[r] if r != -1 else current_id

def _fmt(val) -> str:
    if isinstance(val, bool):
        return "yes" if val else "no"
    return str(val) if val else "—"

# ── edit a single config field ────────────────────────────────────────────────
def _edit_field(win, cfg: Config, idx: int) -> None:
    wayland = _is_wayland(cfg.desktop)
    if   idx == 0:
        v = text_prompt(win, "Main (non-root) username:", cfg.username)
        if v: cfg.username = v
    elif idx == 1:
        cfg.seat_stack = _pick(win, "Seat stack:", SEAT_OPTS, cfg.seat_stack)
    elif idx == 2:
        cfg.desktop = _pick(win, "Desktop / WM:", DESKTOP_OPTS, cfg.desktop)
        # reset launcher default when session type changes
        wayland = _is_wayland(cfg.desktop)
        if wayland and cfg.launcher == "rofi":  cfg.launcher = "wofi"
        if not wayland and cfg.launcher == "wofi": cfg.launcher = "rofi"
    elif idx == 3:
        cfg.login_manager = _pick(win, "Login manager:", LM_OPTS, cfg.login_manager)
        if cfg.login_manager == "sddm" and cfg.seat_stack != "elogind":
            cfg.seat_stack = "elogind"
    elif idx == 4:
        cfg.browser = _pick(win, "Browser:", BROWSER_OPTS, cfg.browser)
    elif idx == 5:
        cfg.gpu = _pick(win, "GPU drivers:", GPU_OPTS, cfg.gpu)
    elif idx == 6:
        opts = LAUNCHER_WAY if wayland else LAUNCHER_X11
        cfg.launcher = _pick(win, "App launcher:", opts, cfg.launcher)
    elif idx == 7:
        opts = FM_KDE if cfg.desktop == "plasma" else (FM_WAY if wayland else FM_X11)
        cfg.file_manager = _pick(win, "File manager:", opts, cfg.file_manager)
    elif idx == 8:
        opts = WALLMGR_WAY if wayland else WALLMGR_X11
        cfg.wallpaper_manager = _pick(win, "Wallpaper manager:", opts, cfg.wallpaper_manager)
    elif idx == 9:
        if cfg.wallpaper_manager == "waypaper":
            opts = WAYBACK_WAY if wayland else WAYBACK_X11
            cfg.wallpaper_backend = _pick(win, "Wallpaper backend:", opts, cfg.wallpaper_backend)
    elif idx == 10: cfg.fonts     = yes_no_prompt(win, "Install fonts?",             cfg.fonts)
    elif idx == 11: cfg.flatpak   = yes_no_prompt(win, "Install Flatpak + Flathub?", cfg.flatpak)
    elif idx == 12: cfg.fastfetch = yes_no_prompt(win, "Install fastfetch?",         cfg.fastfetch)
    elif idx == 13: cfg.dev_tools = yes_no_prompt(win, "Install dev tools?",         cfg.dev_tools)
    elif idx == 14: cfg.gaming    = yes_no_prompt(win, "Install gaming / multilib?", cfg.gaming)

# ── main configuration screen ─────────────────────────────────────────────────
SEPARATOR = ("─" * 44, "")

def _build_rows(cfg: Config) -> List[Tuple[str, str]]:
    return [
        ("Username",           _fmt(cfg.username)),
        ("Seat stack",         _fmt(cfg.seat_stack)),
        ("Desktop / WM",       _fmt(cfg.desktop)),
        ("Login manager",      _fmt(cfg.login_manager)),
        ("Browser",            _fmt(cfg.browser)),
        ("GPU drivers",        _fmt(cfg.gpu)),
        ("App launcher",       _fmt(cfg.launcher)),
        ("File manager",       _fmt(cfg.file_manager)),
        ("Wallpaper manager",  _fmt(cfg.wallpaper_manager)),
        ("Wallpaper backend",  _fmt(cfg.wallpaper_backend)),
        ("Fonts",              _fmt(cfg.fonts)),
        ("Flatpak + Flathub",  _fmt(cfg.flatpak)),
        ("Fastfetch",          _fmt(cfg.fastfetch)),
        ("Dev tools",          _fmt(cfg.dev_tools)),
        ("Gaming / multilib",  _fmt(cfg.gaming)),
        SEPARATOR,
        ("  ► Start installation", ""),
        ("  ✕ Quit",              ""),
    ]

INSTALL_IDX = 16
QUIT_IDX    = 17

def run_main_menu(stdscr, cfg: Config) -> bool:
    """Returns True → install, False → quit."""
    curses.curs_set(0)
    idx = 0
    while True:
        rows   = _build_rows(cfg)
        h, w   = stdscr.getmaxyx()
        stdscr.clear()
        hdr_h  = draw_header(stdscr)
        label_w = max(len(r[0]) for r in rows) + 2
        ver = f"void-installer  v{VERSION}"
        _safe_addstr(stdscr, hdr_h, max(0, w - len(ver) - 2), ver,
                     curses.color_pair(CP_DIM))

        base = hdr_h + 2
        for i, (label, val) in enumerate(rows):
            r = base + i
            if r >= h - 1:
                break
            sel = (i == idx)
            if label.startswith("─"):
                _safe_addstr(stdscr, r, 2, "  " + label, curses.color_pair(CP_DIM))
                continue
            if label.startswith("  ►"):
                a = (curses.color_pair(CP_HILIGHT) if sel else
                     curses.color_pair(CP_GREEN)) | curses.A_BOLD
                _safe_addstr(stdscr, r, 2, f"{label:<{label_w + 6}}", a)
                continue
            if label.startswith("  ✕"):
                a = (curses.color_pair(CP_HILIGHT) if sel else
                     curses.color_pair(CP_ERR)) | curses.A_BOLD
                _safe_addstr(stdscr, r, 2, f"{label:<{label_w + 6}}", a)
                continue
            a = (curses.color_pair(CP_HILIGHT) if sel else
                 curses.color_pair(CP_NORMAL))
            line = f"  {label:<{label_w}}  {val}"
            _safe_addstr(stdscr, r, 2, line, a)

        footer = "  ↑/k  ↓/j  navigate    Enter  edit    i  install    q  quit  "
        _safe_addstr(stdscr, h - 1, 0, footer[:w - 1], curses.color_pair(CP_DIM))
        stdscr.refresh()

        key = stdscr.getch()
        if key in (curses.KEY_UP, ord('k')):
            idx = (idx - 1) % len(rows)
            while rows[idx][0].startswith("─"):
                idx = (idx - 1) % len(rows)
        elif key in (curses.KEY_DOWN, ord('j')):
            idx = (idx + 1) % len(rows)
            while rows[idx][0].startswith("─"):
                idx = (idx + 1) % len(rows)
        elif key in (curses.KEY_ENTER, ord('\n'), ord('\r'), ord(' ')):
            if idx == QUIT_IDX:    return False
            if idx == INSTALL_IDX: return True
            _edit_field(stdscr, cfg, idx)
        elif key in (ord('i'), ord('I')):
            return True
        elif key in (ord('q'), ord('Q')):
            return False

# ── logging helper ────────────────────────────────────────────────────────────
_log_fh = None

def _open_log() -> None:
    global _log_fh
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    _log_fh = open(LOG_FILE, "a")

def _log(msg: str) -> None:
    ts = time.strftime("%H:%M:%S")
    line = f"[{ts}] {msg}"
    if _log_fh:
        _log_fh.write(line + "\n")
        _log_fh.flush()

# ── subprocess / xbps helpers ─────────────────────────────────────────────────
def _run(cmd: List[str], check: bool = True) -> subprocess.CompletedProcess:
    _log("RUN: " + " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.stdout: _log(r.stdout.rstrip())
    if r.stderr: _log(r.stderr.rstrip())
    if check and r.returncode != 0:
        raise RuntimeError(f"Command failed ({r.returncode}): {' '.join(cmd)}")
    return r

def have_cmd(name: str) -> bool:
    import shutil
    return shutil.which(name) is not None

def xbps_sync() -> None:
    _run(["xbps-install", "-Sy"])

def xbps_full_update() -> None:
    _run(["xbps-install", "-Suy", "-y"])

def xbps_is_installed(pkg: str) -> bool:
    return _run(["xbps-query", pkg], check=False).returncode == 0

def xbps_pkg_available(pkg: str) -> bool:
    return _run(["xbps-query", "-R", pkg], check=False).returncode == 0

def xbps_install(*pkgs: str) -> None:
    to_install = [p for p in pkgs if not xbps_is_installed(p)]
    if to_install:
        _log(f"Installing: {' '.join(to_install)}")
        _run(["xbps-install", "-y"] + list(to_install))
    else:
        _log(f"Already installed (skipping): {' '.join(pkgs)}")

def xbps_install_if_available(*pkgs: str) -> None:
    available = [p for p in pkgs if xbps_pkg_available(p)]
    if available:
        xbps_install(*available)
    else:
        _log(f"Packages not found (skipping): {' '.join(pkgs)}")

def xbps_install_first_available(label: str, *pkgs: str) -> bool:
    for p in pkgs:
        if xbps_pkg_available(p):
            xbps_install(p)
            return True
    _log(f"No package found for {label}. Tried: {' '.join(pkgs)}")
    return False

def safe_mkdir(path: str) -> None:
    os.makedirs(path, exist_ok=True)

def enable_service(name: str) -> None:
    src = f"/etc/sv/{name}"
    dst = f"/var/service/{name}"
    if not os.path.isdir(src):
        _log(f"WARN: service {name} not found at {src}")
        return
    if not os.path.exists(dst):
        os.symlink(src, dst)
        _log(f"Enabled service: {name}")
    else:
        _log(f"Service already enabled: {name}")

def disable_service(name: str) -> None:
    dst = f"/var/service/{name}"
    if os.path.islink(dst):
        os.unlink(dst)
        _log(f"Disabled service: {name}")

def write_file(path: str, content: str, mode: int = 0o644) -> None:
    safe_mkdir(os.path.dirname(path))
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, mode)

def chown_r(path: str, user: str) -> None:
    _run(["chown", "-R", f"{user}:{user}", path], check=False)

def as_user(user: str, cmd: str) -> None:
    _run(["sudo", "-u", user, "-H", "bash", "-lc", cmd], check=False)

# ── environment checks ────────────────────────────────────────────────────────
def require_root() -> None:
    if os.geteuid() != 0:
        print("void-installer must be run as root (sudo python3 void_installer.py)",
              file=sys.stderr)
        sys.exit(1)

def detect_void() -> None:
    if not os.path.exists("/etc/os-release"):
        raise RuntimeError("/etc/os-release missing")
    with open("/etc/os-release") as f:
        text = f.read()
    if 'ID=void' not in text and 'ID="void"' not in text:
        _log("WARN: does not look like Void Linux — continuing anyway")

def detect_arch() -> str:
    import platform
    m = platform.machine()
    return "aarch64" if m in ("aarch64", "arm64") else m

def detect_libc() -> str:
    if have_cmd("ldd"):
        r = subprocess.run(["ldd", "--version"], capture_output=True, text=True)
        if "musl" in (r.stdout + r.stderr).lower():
            return "musl"
    return "gnu"

# ── installation steps ────────────────────────────────────────────────────────
def step_enable_repos() -> None:
    arch = detect_arch()
    xbps_sync()
    xbps_install_if_available("void-repo-nonfree")
    if arch == "x86_64":
        xbps_install_if_available("void-repo-multilib")
        xbps_install_if_available("void-repo-multilib-nonfree")
    xbps_sync()

def step_bootstrap_tools() -> None:
    xbps_install("ca-certificates", "sudo", "git", "curl", "xtools")

def step_core_services(seat_stack: str) -> None:
    xbps_install("dbus", "polkit")
    enable_service("dbus")
    if seat_stack == "elogind":
        xbps_install("elogind")
        enable_service("elogind")
        disable_service("seatd")
    else:
        xbps_install("seatd")
        enable_service("seatd")
        disable_service("elogind")

def step_pipewire_bluetooth() -> None:
    xbps_install("pipewire", "wireplumber", "pulseaudio-utils",
                 "alsa-utils", "pavucontrol", "bluez", "blueman")
    xbps_install_if_available("libspa-bluetooth", "rfkill")
    enable_service("bluetoothd")

def step_gpu_drivers(choice: str) -> None:
    vendor = choice
    if choice == "auto":
        vendor = _auto_detect_gpu()
    _log(f"GPU vendor: {vendor}")
    if vendor == "nvidia":
        xbps_install("nvidia")
        xbps_install_if_available("nvidia-libs-32bit")
        _configure_nvidia_kms()
    elif vendor == "amd":
        xbps_install("mesa", "mesa-dri", "vulkan-loader")
        xbps_install_if_available("vulkan-radeon")
    elif vendor == "intel":
        xbps_install("mesa", "mesa-dri", "vulkan-loader")
    else:
        _log("WARN: no GPU detected — skipping driver install")

def _auto_detect_gpu() -> str:
    if not have_cmd("lspci"):
        xbps_install_if_available("pciutils")
    if not have_cmd("lspci"):
        return "none"
    r = subprocess.run(["lspci", "-nn"], capture_output=True, text=True)
    out = r.stdout.lower()
    for line in out.splitlines():
        if any(k in line for k in ("vga", "3d", "display")):
            if "nvidia" in line: return "nvidia"
            if "amd"    in line or "ati" in line: return "amd"
            if "intel"  in line: return "intel"
    return "none"

def _configure_nvidia_kms() -> None:
    grub = "/etc/default/grub"
    if not os.path.exists(grub):
        _log("WARN: /etc/default/grub not found — add nvidia_drm.modeset=1 manually")
        return
    with open(grub) as f:
        content = f.read()
    if "nvidia_drm.modeset=1" in content:
        return
    content = content.replace(
        'GRUB_CMDLINE_LINUX_DEFAULT="',
        'GRUB_CMDLINE_LINUX_DEFAULT="nvidia_drm.modeset=1 ')
    with open(grub, "w") as f:
        f.write(content)
    if have_cmd("grub-mkconfig") and os.path.isdir("/boot/grub"):
        _run(["grub-mkconfig", "-o", "/boot/grub/grub.cfg"], check=False)

def step_install_de(desktop: str) -> None:
    if desktop in ("i3",):
        _x11_base()
        xbps_install("i3", "i3status", "i3lock", "dmenu", "picom", "feh", "alacritty")
    elif desktop == "plasma":
        _x11_base()
        if not xbps_install_first_available("KDE", "kde5"):
            xbps_install("plasma-desktop", "konsole", "dolphin")
    elif desktop == "dwm":
        _x11_base()
        xbps_install("dwm", "dmenu", "feh", "picom", "sxhkd")
        xbps_install_if_available("st", "alacritty")
    elif desktop == "awesome":
        _x11_base()
        xbps_install("awesome", "feh", "picom", "alacritty")
    elif desktop == "herbstluftwm":
        _x11_base()
        xbps_install("herbstluftwm", "dmenu", "feh", "picom", "alacritty")
    elif desktop == "xfce":
        _x11_base()
        xbps_install_first_available("XFCE", "xfce4", "xfce")
        xbps_install_if_available("xfce4-terminal", "thunar")
    elif desktop == "gnome":
        _x11_base(); _wayland_base()
        xbps_install_first_available("GNOME", "gnome", "gnome-core", "gnome-session")
        xbps_install_if_available("gnome-terminal", "nautilus")
    elif desktop == "mate":
        _x11_base()
        xbps_install_first_available("MATE", "mate", "mate-desktop")
        xbps_install_if_available("mate-terminal", "caja")
    elif desktop == "river":
        _wayland_base()
        xbps_install("river", "foot", "swaybg", "grim", "slurp", "wl-clipboard")
    elif desktop == "niri":
        _wayland_base()
        xbps_install_if_available("niri")
        xbps_install("foot", "swaybg", "grim", "slurp", "wl-clipboard")
    elif desktop == "sway":
        _wayland_base()
        xbps_install("sway", "foot", "swaybg", "grim", "slurp", "wl-clipboard")
    elif desktop == "swayfx":
        _wayland_base()
        xbps_install_first_available("swayfx/sway", "swayfx", "sway")
        xbps_install_if_available("foot", "swaybg", "grim", "slurp", "wl-clipboard")
    elif desktop == "hyprland":
        _wayland_base()
        xbps_install_if_available("kitty", "swaybg", "grim", "slurp", "wl-clipboard")
        _install_hyprland_experimental()

def _x11_base() -> None:
    xbps_install("xorg-minimal", "xinit", "xauth", "xsetroot",
                 "xrandr", "xdg-utils", "xdg-user-dirs", "polybar")

def _wayland_base() -> None:
    xbps_install("wayland", "wayland-protocols", "xdg-utils", "xdg-user-dirs")
    xbps_install_first_available("Waybar", "Waybar", "waybar")

def _install_hyprland_experimental() -> None:
    arch = detect_arch(); libc = detect_libc()
    repo_map = {
        ("x86_64", "gnu"):   "x86_64",
        ("x86_64", "musl"):  "x86_64-musl",
        ("aarch64", "gnu"):  "aarch64",
        ("aarch64", "musl"): "aarch64-musl",
    }
    repo_arch = repo_map.get((arch, libc))
    if repo_arch:
        conf = "/etc/xbps.d/20-repository-extra.conf"
        if not os.path.exists(conf):
            url = f"https://raw.githubusercontent.com/Encoded14/void-extra/repository-{repo_arch}"
            write_file(conf, f"repository={url}\n")
        _run(["xbps-install", "-S"], check=False)
    if xbps_pkg_available("hyprland"):
        xbps_install("hyprland")
    xbps_install_if_available(
        "xorg-server-xwayland", "wofi", "mako", "kitty",
        "grim", "slurp", "wl-clipboard", "polkit", "polkit-gnome",
        "xdg-desktop-portal", "xdg-desktop-portal-hyprland", "xdg-desktop-portal-gtk")
    xbps_install_first_available("Waybar", "Waybar", "waybar")

def step_login_manager(lm: str, user: str) -> None:
    if lm == "sddm":
        xbps_install("sddm", "xorg-minimal", "xauth")
        safe_mkdir("/etc/sddm.conf.d")
        write_file("/etc/sddm.conf.d/10-void-installer.conf",
                   "[General]\nDisplayServer=x11\n")
        enable_service("sddm")
    elif lm == "lightdm":
        xbps_install("lightdm", "lightdm-gtk3-greeter")
        enable_service("lightdm")
    elif lm == "greetd":
        xbps_install("greetd", "tuigreet")
        enable_service("greetd")
    elif lm == "ly":
        if xbps_pkg_available("ly"):
            xbps_install("ly")
            xbps_install_if_available("brightnessctl")
            disable_service("agetty-tty2")
            enable_service("ly")
        else:
            _log("WARN: ly not found in repos")

def step_launcher(launcher: str) -> None:
    if launcher not in ("none", "dmenu", ""):
        xbps_install_if_available(launcher)
    elif launcher == "dmenu":
        xbps_install_if_available("dmenu")

def step_file_manager(fm: str) -> None:
    if fm and fm != "none":
        xbps_install_if_available(fm)

def step_fonts() -> None:
    xbps_install_if_available("fontconfig")
    if not xbps_install_first_available("baseline fonts", "dejavu-fonts-ttf", "xorg-fonts"):
        return
    xbps_install_if_available("noto-fonts-ttf", "noto-fonts-cjk", "noto-fonts-emoji",
                               "nerd-fonts", "nerd-fonts-ttf")
    if have_cmd("xbps-reconfigure"):
        _run(["xbps-reconfigure", "-f", "fontconfig"], check=False)

def step_flatpak() -> None:
    xbps_install("flatpak")
    r = _run(["flatpak", "remote-list", "--system"], check=False)
    if "flathub" not in r.stdout.lower():
        _run(["flatpak", "remote-add", "--system", "--if-not-exists",
              "flathub", "https://flathub.org/repo/flathub.flatpakrepo"])

def step_fastfetch() -> None:
    xbps_install_if_available("fastfetch")

def step_dev_tools() -> None:
    xbps_install("base-devel", "git", "curl", "wget", "ca-certificates",
                 "pkg-config", "cmake", "ninja", "python3", "python3-pip",
                 "nodejs", "go", "rust", "cargo", "gdb", "strace")
    xbps_install_if_available("neovim", "python3-gobject", "cairo", "cairo-devel")

def step_gaming() -> None:
    if detect_arch() != "x86_64":
        _log("Non-x86_64: skipping gaming / multilib")
        return
    xbps_install_if_available("mesa", "mesa-dri", "vulkan-loader")
    xbps_install_if_available("mesa-dri-32bit", "vulkan-loader-32bit")
    xbps_install_if_available("steam", "libgcc-32bit", "libstdc++-32bit",
                               "libdrm-32bit", "libglvnd-32bit")

def step_browser(browser: str) -> None:
    if xbps_pkg_available(browser):
        xbps_install(browser)
    else:
        _log(f"WARN: {browser} not found — falling back to firefox")
        xbps_install("firefox")

def step_wallpaper_manager(mgr: str, backend: str, kind: str, user: str) -> None:
    if mgr in ("nitrogen", "azote"):
        xbps_install_if_available(mgr)
    elif mgr == "waypaper":
        _install_waypaper_backend(backend, kind)
        xbps_install("base-devel", "pkg-config", "python3-devel",
                     "cairo-devel", "gobject-introspection")
        xbps_install_first_available("PyGObject", "python3-gobject", "python3-gi")
        xbps_install_first_available("python-imageio", "python3-imageio", "python-imageio")
        xbps_install_first_available("python-screeninfo", "python3-screeninfo", "python-screeninfo")
        xbps_install_if_available("python3", "python3-pip")
        _install_pipx(user)
        as_user(user, "pipx install waypaper 2>/dev/null || pipx upgrade waypaper || true")

def _install_waypaper_backend(backend: str, kind: str) -> None:
    if backend in ("swww",):
        xbps_install_first_available("swww/awww", "swww", "awww")
    elif backend:
        xbps_install_if_available(backend)

def _install_pipx(user: str) -> None:
    if not xbps_install_first_available("pipx", "pipx", "python3-pipx"):
        as_user(user, "python3 -m pip install --user pipx || true")

def step_install_wallpaper() -> None:
    if not os.path.exists(WALLPAPER_REPO):
        _log(f"WARN: sample wallpaper not found at {WALLPAPER_REPO}")
        return
    safe_mkdir(os.path.dirname(WALLPAPER_SYS))
    import shutil
    shutil.copy2(WALLPAPER_REPO, WALLPAPER_SYS)
    os.chmod(WALLPAPER_SYS, 0o644)

def step_user_groups(seat_stack: str, user: str) -> None:
    if seat_stack == "seatd":
        _run(["usermod", "-aG", "seat", user], check=False)
    for g in ("audio", "video", "input", "bluetooth"):
        _run(["usermod", "-aG", g, user], check=False)

def step_user_autostart(user: str) -> None:
    base = f"/home/{user}/.config"
    for d in (base, f"{base}/autostart", f"{base}/pipewire/pipewire.conf.d"):
        safe_mkdir(d)
    as_user(user, "xdg-user-dirs-update || true")
    for name, exe in (("pipewire", "pipewire"), ("wireplumber", "wireplumber")):
        src = f"/usr/share/applications/{name}.desktop"
        dst = f"{base}/autostart/{name}.desktop"
        if os.path.exists(src):
            try: os.symlink(src, dst)
            except FileExistsError: pass
        else:
            write_file(dst,
                f"[Desktop Entry]\nType=Application\nName={name}\nExec={exe}\n"
                "X-GNOME-Autostart-enabled=true\n")
    for src, dst_name in (
        ("/usr/share/examples/pipewire/20-pipewire-pulse.conf",
         "20-pipewire-pulse.conf"),
        ("/usr/share/examples/wireplumber/10-wireplumber.conf",
         "10-wireplumber.conf"),
    ):
        if os.path.exists(src):
            dst = f"{base}/pipewire/pipewire.conf.d/{dst_name}"
            try: os.symlink(src, dst)
            except FileExistsError: pass
    chown_r(base, user)

def step_session_configs(cfg: Config) -> None:
    """Write WM/DE config files into the user's home."""
    u = cfg.username
    desktop = cfg.desktop
    wayland = _is_wayland(desktop)
    launcher_cmd = _launcher_cmd(cfg.launcher)
    wp = WALLPAPER_SYS

    if desktop == "i3":
        _write_i3_config(u, launcher_cmd, wp)
        _write_xinitrc(u, "i3", wp)
    elif desktop == "plasma":
        _write_xinitrc(u, "startplasma-x11", wp)
    elif desktop == "dwm":
        _write_xinitrc(u, "dwm", wp)
    elif desktop == "awesome":
        _write_xinitrc(u, "awesome", wp)
    elif desktop == "herbstluftwm":
        _write_herbstluftwm_config(u, launcher_cmd, wp)
        _write_xinitrc(u, "herbstluftwm", wp)
    elif desktop == "xfce":
        _write_xinitrc(u, "startxfce4", wp)
    elif desktop == "gnome":
        _write_xinitrc(u, "gnome-session", wp)
    elif desktop == "mate":
        _write_xinitrc(u, "mate-session", wp)
    elif desktop == "river":
        _write_river_init(u, launcher_cmd, wp)
    elif desktop == "niri":
        _write_niri_config(u, launcher_cmd, wp)
    elif desktop in ("sway", "swayfx"):
        _write_sway_config(u, launcher_cmd, wp)
    elif desktop == "hyprland":
        _write_hyprland_config(u, launcher_cmd, wp, cfg.wallpaper_manager)

    if cfg.login_manager == "greetd":
        _write_greetd_config(desktop, u)

def _launcher_cmd(launcher: str) -> str:
    return {"rofi":  "rofi -show drun",
            "dmenu": "dmenu_run",
            "fuzzel": "fuzzel",
            "wofi":  "wofi --show drun"}.get(launcher, "")

def _write_xinitrc(user: str, session_cmd: str, wp: str) -> None:
    path = f"/home/{user}/.xinitrc"
    write_file(path, textwrap.dedent(f"""\
        #!/usr/bin/env sh
        export XDG_CURRENT_DESKTOP={session_cmd}
        export XDG_SESSION_TYPE=x11
        command -v feh >/dev/null 2>&1 && feh --bg-scale "{wp}" >/dev/null 2>&1 || true
        exec {session_cmd}
    """), mode=0o755)
    _run(["chown", f"{user}:{user}", path], check=False)

def _write_i3_config(user: str, launcher_cmd: str, wp: str) -> None:
    safe_mkdir(f"/home/{user}/.config/i3")
    safe_mkdir(f"/home/{user}/.config/i3status")
    launcher_line = (f"bindsym $mod+d exec --no-startup-id {launcher_cmd}\n"
                     if launcher_cmd else "")
    write_file(f"/home/{user}/.config/i3/config", textwrap.dedent(f"""\
        # i3 config (generated by void-installer)
        set $mod Mod4
        font pango:monospace 10
        bindsym $mod+Return exec alacritty
        {launcher_line}
        bindsym $mod+Shift+q kill
        bindsym $mod+Shift+r restart
        bindsym $mod+h focus left
        bindsym $mod+j focus down
        bindsym $mod+k focus up
        bindsym $mod+l focus right
        bindsym $mod+Shift+h move left
        bindsym $mod+Shift+j move down
        bindsym $mod+Shift+k move up
        bindsym $mod+Shift+l move right
        bindsym $mod+v split v
        bindsym $mod+b split h
        bindsym $mod+f fullscreen toggle
        set $ws1 "1"
        set $ws2 "2"
        set $ws3 "3"
        bindsym $mod+1 workspace $ws1
        bindsym $mod+2 workspace $ws2
        bindsym $mod+3 workspace $ws3
        bindsym $mod+Shift+1 move container to workspace $ws1; workspace $ws1
        bindsym $mod+Shift+2 move container to workspace $ws2; workspace $ws2
        bindsym $mod+Shift+3 move container to workspace $ws3; workspace $ws3
        bar {{ status_command i3status }}
        exec --no-startup-id picom
        exec --no-startup-id feh --bg-scale "{wp}" 2>/dev/null || true
        exec --no-startup-id pipewire
        exec --no-startup-id wireplumber
        exec --no-startup-id blueman-applet
    """))
    write_file(f"/home/{user}/.config/i3status/config", textwrap.dedent("""\
        general { colors = true  interval = 5 }
        order += "disk /"
        order += "wireless _first_"
        order += "ethernet _first_"
        order += "battery all"
        order += "volume master"
        order += "tztime local"
        disk "/" { format = "Disk %avail" }
        wireless "_first_" { format_up = "W: %quality at %essid %ip"  format_down = "W: down" }
        ethernet "_first_" { format_up = "E: %ip"  format_down = "E: down" }
        battery "all" { format = "%status %percentage %remaining" }
        volume "master" { format = "Vol %volume" }
        tztime "local" { format = "%Y-%m-%d %H:%M" }
    """))
    chown_r(f"/home/{user}/.config/i3", user)
    chown_r(f"/home/{user}/.config/i3status", user)

def _write_sway_config(user: str, launcher_cmd: str, wp: str) -> None:
    safe_mkdir(f"/home/{user}/.config/sway")
    launcher_line = f"bindsym $mod+d exec {launcher_cmd}\n" if launcher_cmd else ""
    write_file(f"/home/{user}/.config/sway/config", textwrap.dedent(f"""\
        # sway config (generated by void-installer)
        set $mod Mod4
        bindsym $mod+Return exec foot
        bindsym $mod+Shift+q kill
        bindsym $mod+Shift+e exit
        bindsym $mod+h focus left
        bindsym $mod+j focus down
        bindsym $mod+k focus up
        bindsym $mod+l focus right
        bindsym $mod+1 workspace number 1
        bindsym $mod+2 workspace number 2
        bindsym $mod+3 workspace number 3
        bindsym $mod+Shift+1 move container to workspace number 1
        bindsym $mod+Shift+r reload
        {launcher_line}
        exec_always dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
        exec pipewire
        exec wireplumber
        exec Waybar
        exec blueman-applet
        output * bg "{wp}" fill
    """))
    chown_r(f"/home/{user}/.config/sway", user)

def _write_hyprland_config(user: str, launcher_cmd: str, wp: str, wall_mgr: str) -> None:
    safe_mkdir(f"/home/{user}/.config/hypr")
    launcher_line = f"bind = SUPER, D, exec, {launcher_cmd}\n" if launcher_cmd else ""
    wp_line = (f"exec-once = swww-daemon\nexec-once = waypaper --restore\n"
               if wall_mgr == "waypaper" else f'exec-once = swaybg -i "{wp}" -m fill\n')
    write_file(f"/home/{user}/.config/hypr/hyprland.conf", textwrap.dedent(f"""\
        # hyprland config (generated by void-installer)
        input {{ kb_layout = us }}
        general {{ gaps_in = 5  gaps_out = 10  border_size = 2 }}
        decoration {{ rounding = 6 }}
        animations {{ enabled = 1 }}
        misc {{ disable_hyprland_logo = 1 }}
        monitor = , preferred, auto, auto
        exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
        exec-once = dbus-update-activation-environment --all
        exec-once = pipewire
        exec-once = wireplumber
        exec-once = waybar
        exec-once = blueman-applet
        {wp_line}
        bind = SUPER, Return, exec, kitty
        bind = SUPER, Q, killactive,
        bind = SUPER SHIFT, E, exit,
        {launcher_line}
    """))
    chown_r(f"/home/{user}/.config/hypr", user)

def _write_river_init(user: str, launcher_cmd: str, wp: str) -> None:
    safe_mkdir(f"/home/{user}/.config/river")
    launcher_line = (f"riverctl map normal Super D spawn '{launcher_cmd}'\n"
                     if launcher_cmd else "")
    write_file(f"/home/{user}/.config/river/init", textwrap.dedent(f"""\
        #!/usr/bin/env bash
        export XDG_SESSION_TYPE=wayland
        export XDG_CURRENT_DESKTOP=river
        command -v dbus-update-activation-environment >/dev/null 2>&1 && \
            dbus-update-activation-environment --all || true
        pgrep -x pipewire   >/dev/null || pipewire &
        pgrep -x wireplumber >/dev/null || wireplumber &
        command -v swaybg >/dev/null && swaybg -i "{wp}" -m fill &
        command -v blueman-applet >/dev/null && blueman-applet &
        command -v Waybar >/dev/null && Waybar &
        riverctl map normal Super Return spawn foot
        {launcher_line}
        riverctl map normal Super Q close
        riverctl map normal Super+Shift E exit
        command -v rivertile >/dev/null 2>&1 && rivertile -view-padding 6 -outer-padding 6 &
        riverctl set-repeat 50 300
    """), mode=0o755)
    chown_r(f"/home/{user}/.config/river", user)

def _write_niri_config(user: str, launcher_cmd: str, wp: str) -> None:
    safe_mkdir(f"/home/{user}/.config/niri")
    launcher_line = f'  Mod4+D spawn "{launcher_cmd}"\n' if launcher_cmd else ""
    write_file(f"/home/{user}/.config/niri/config.kdl", textwrap.dedent(f"""\
        // niri config (generated by void-installer)
        environment {{ XDG_SESSION_TYPE "wayland"  XDG_CURRENT_DESKTOP "niri" }}
        input {{ repeat-rate 50  repeat-delay 300 }}
        spawn-at-startup "pipewire"
        spawn-at-startup "wireplumber"
        spawn-at-startup "blueman-applet"
        spawn-at-startup "Waybar"
        spawn-at-startup "swaybg" "-i" "{wp}" "-m" "fill"
        bindings {{
          Mod4+Return spawn "foot"
          {launcher_line}
          Mod4+Q close-window
          Mod4+Shift+E quit
        }}
    """))
    chown_r(f"/home/{user}/.config/niri", user)

def _write_herbstluftwm_config(user: str, launcher_cmd: str, wp: str) -> None:
    safe_mkdir(f"/home/{user}/.config/herbstluftwm")
    launcher_line = (f'hc keybind "$Mod-d" spawn {launcher_cmd}\n'
                     if launcher_cmd else "")
    write_file(f"/home/{user}/.config/herbstluftwm/autostart", textwrap.dedent(f"""\
        #!/usr/bin/env bash
        set -eu
        hc() {{ herbstclient "$@"; }}
        hc emit_hook reload
        hc set frame_border_width 2
        hc set window_border_width 2
        hc set frame_gap 8
        for i in 1 2 3 4 5 6 7 8 9; do hc add "$i" >/dev/null 2>&1 || true; done
        hc use 1
        Mod=Mod4
        hc keybind "$Mod-Return" spawn alacritty
        {launcher_line}
        hc keybind "$Mod-Shift-q" close
        hc keybind "$Mod-Shift-e" quit
        pgrep -x pipewire    >/dev/null || pipewire &
        pgrep -x wireplumber >/dev/null || wireplumber &
        command -v picom >/dev/null && picom &
        command -v feh   >/dev/null && feh --bg-scale "{wp}" &
    """), mode=0o755)
    chown_r(f"/home/{user}/.config/herbstluftwm", user)

def _write_greetd_config(desktop: str, user: str) -> None:
    WAYLAND_CMDS = {
        "river":    "/usr/local/bin/start-river",
        "niri":     "/usr/local/bin/start-niri",
        "hyprland": "/usr/local/bin/start-hyprland",
        "sway":     "/usr/local/bin/start-sway",
        "swayfx":   "/usr/local/bin/start-swayfx",
    }
    cmd = WAYLAND_CMDS.get(desktop, "startx")
    safe_mkdir("/etc/greetd")
    write_file("/etc/greetd/config.toml", textwrap.dedent(f"""\
        [terminal]
        vt = 1
        [default_session]
        command = "tuigreet --time --cmd {cmd}"
        user = "{user}"
    """))

# ── installation progress TUI ─────────────────────────────────────────────────
def run_install_screen(stdscr, cfg: Config) -> None:
    """Run all install steps with a live progress UI."""
    _open_log()
    curses.curs_set(0)

    wayland = _is_wayland(cfg.desktop)
    kind    = "wayland" if wayland else "x11"

    steps = [
        ("Full system update",              lambda: xbps_full_update()),
        ("Bootstrap tools",                 lambda: step_bootstrap_tools()),
        ("Enable Void repos",               lambda: step_enable_repos()),
        ("Core services",                   lambda: step_core_services(cfg.seat_stack)),
        ("PipeWire + Bluetooth",            lambda: step_pipewire_bluetooth()),
        ("GPU drivers",                     lambda: step_gpu_drivers(cfg.gpu)),
        ("Desktop / WM",                    lambda: step_install_de(cfg.desktop)),
        ("Login manager",                   lambda: step_login_manager(cfg.login_manager, cfg.username)),
        ("App launcher",                    lambda: step_launcher(cfg.launcher)),
        ("File manager",                    lambda: step_file_manager(cfg.file_manager)),
        ("Sample wallpaper",                lambda: step_install_wallpaper()),
        ("User groups",                     lambda: step_user_groups(cfg.seat_stack, cfg.username)),
        ("User autostart bits",             lambda: step_user_autostart(cfg.username)),
        ("Session / WM configs",            lambda: step_session_configs(cfg)),
        ("Browser",                         lambda: step_browser(cfg.browser)),
    ]
    if cfg.fonts:
        steps.insert(5, ("Fonts", lambda: step_fonts()))
    if cfg.fastfetch:
        steps.append(("Fastfetch", lambda: step_fastfetch()))
    if cfg.dev_tools:
        steps.append(("Dev tools", lambda: step_dev_tools()))
    if cfg.gaming:
        steps.append(("Gaming / multilib", lambda: step_gaming()))
    if cfg.flatpak:
        steps.append(("Flatpak + Flathub", lambda: step_flatpak()))
    if cfg.wallpaper_manager != "none":
        steps.append(("Wallpaper manager",
                       lambda: step_wallpaper_manager(cfg.wallpaper_manager,
                                                      cfg.wallpaper_backend,
                                                      kind, cfg.username)))

    total   = len(steps)
    log_buf: List[str] = []

    for step_n, (label, fn) in enumerate(steps):
        pct     = int(step_n * 100 / total)
        bar_len = 36
        filled  = int(pct * bar_len / 100)
        bar     = "█" * filled + "░" * (bar_len - filled)

        h, w = stdscr.getmaxyx()
        stdscr.clear()

        # mini header (just text, no big art during install)
        title = "  VOID INSTALLER — installing…"
        _safe_addstr(stdscr, 0, 0, title,
                     curses.color_pair(CP_GREEN) | curses.A_BOLD)

        _safe_addstr(stdscr, 2, 2,
                     f"Step {step_n + 1}/{total}  [{bar}]  {pct}%",
                     curses.color_pair(CP_GREEN))
        _safe_addstr(stdscr, 3, 2, f"► {label}",
                     curses.color_pair(CP_NORMAL) | curses.A_BOLD)

        # last log lines
        log_start = 5
        for i, line in enumerate(log_buf[-(h - log_start - 1):]):
            _safe_addstr(stdscr, log_start + i, 2, line[:w - 3],
                         curses.color_pair(CP_DIM))

        stdscr.refresh()

        try:
            fn()
            msg = f"[OK] {label}"
        except Exception as exc:
            msg = f"[ERR] {label}: {exc}"
            _log(msg)
            # show error in red and wait for keypress
            _safe_addstr(stdscr, 3, 2,
                         f"ERROR: {exc}"[:w - 3],
                         curses.color_pair(CP_ERR) | curses.A_BOLD)
            _safe_addstr(stdscr, h - 1, 0,
                         "  Press any key to continue…",
                         curses.color_pair(CP_WARN))
            stdscr.refresh()
            stdscr.getch()

        log_buf.append(msg)

    # done screen
    h, w = stdscr.getmaxyx()
    stdscr.clear()
    _safe_addstr(stdscr, 0, 0, "  VOID INSTALLER — done!",
                 curses.color_pair(CP_GREEN) | curses.A_BOLD)
    notes = [
        "",
        "Installation complete.",
        "",
        f"  Log file : {LOG_FILE}",
        f"  Desktop  : {cfg.desktop}",
        f"  LM       : {cfg.login_manager}",
        "",
        "Reboot now to apply drivers and services.",
        "",
        "  Press r to reboot, any other key to exit.",
    ]
    for i, line in enumerate(notes):
        _safe_addstr(stdscr, 2 + i, 2, line, curses.color_pair(CP_NORMAL))
    stdscr.refresh()
    key = stdscr.getch()
    if key in (ord('r'), ord('R')):
        _run(["reboot"], check=False)

# ── entry point ───────────────────────────────────────────────────────────────
def _tui_main(stdscr) -> None:
    _init_colors()
    curses.curs_set(0)
    stdscr.keypad(True)

    cfg = Config()
    # Pre-fill username from SUDO_USER if available
    cfg.username = os.environ.get("SUDO_USER", "")

    proceed = run_main_menu(stdscr, cfg)
    if not proceed:
        return

    # Validate username
    while not cfg.username:
        cfg.username = text_prompt(stdscr, "Username is required. Enter username:", "")

    run_install_screen(stdscr, cfg)


def main() -> None:
    require_root()
    detect_void()
    try:
        curses.wrapper(_tui_main)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
