#!/usr/bin/env bash
set -euo pipefail

# void-auto-setup.sh
# Purpose: Post-install installer/configurator for a fresh Void Linux install (runit).
# - Enables repos (nonfree/multilib)
# - Installs dbus + (elogind OR seatd)
# - Installs PipeWire + WirePlumber + Bluetooth (BlueZ + Blueman + libspa-bluetooth)
# - Installs GPU drivers (NVIDIA proprietary supported via Void nonfree; AMD uses Mesa/Vulkan with optional AMDVLK)
# - Prompts for Desktop/WM: i3 (default), KDE Plasma, river, dwm, niri, sway, awesome, herbstluftwm
# - Generates usable starter configs for each
# - Prompts for browser (Firefox default)
# - Optional Flatpak + Flathub
# - Installs dev tools
# - Enables multilib + 32-bit libs for gaming
#
# Run as root (sudo). Reboot only at the end (optional).

SCRIPT_VERSION="2026-02-27"
LOG_FILE="/var/log/void-auto-setup.log"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WALLPAPER_REPO_PATH="${SCRIPT_DIR}/wallpaper/sample.jpg"
WALLPAPER_SYSTEM_PATH="/usr/share/backgrounds/void-auto-setup/sample.jpg"

mkdir -p /var/log
exec > >(tee -a "${LOG_FILE}") 2>&1

# ---------------- helpers ----------------
color() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
info()  { printf "%s %s\n" "$(color '1;34' '[INFO]')" "$*"; }
warn()  { printf "%s %s\n" "$(color '1;33' '[WARN]')" "$*"; }
err()   { printf "%s %s\n" "$(color '1;31' '[ERR ]')" "$*"; }
die()   { err "$*"; exit 1; }

PROGRESS_TTY=""
if [[ -w /dev/tty ]]; then
  PROGRESS_TTY="/dev/tty"
fi

PROGRESS_TOTAL=0
PROGRESS_DONE=0
PROGRESS_START_EPOCH=0

fmt_mmss() {
  local s="${1:-0}"
  if [[ "$s" -lt 0 ]]; then s=0; fi
  printf "%02d:%02d" $((s / 60)) $((s % 60))
}

progress_init() {
  PROGRESS_TOTAL="${1:-0}"
  PROGRESS_DONE=0
  PROGRESS_START_EPOCH="$(date +%s)"
}

progress_out() { # fmt...
  if [[ -n "${PROGRESS_TTY}" ]]; then
    # shellcheck disable=SC2059
    printf "$@" >"${PROGRESS_TTY}"
  else
    # shellcheck disable=SC2059
    printf "$@"
  fi
}

progress_render() { # status_text, done_override(optional)
  local status="${1:-}"
  local done="${2:-$PROGRESS_DONE}"
  local total="${PROGRESS_TOTAL:-0}"
  local now elapsed avg remaining percent bar_len filled empty

  now="$(date +%s)"
  elapsed=$((now - PROGRESS_START_EPOCH))

  if [[ "$total" -le 0 ]]; then
    percent=0
  else
    percent=$((done * 100 / total))
  fi

  if [[ "$done" -gt 0 && "$total" -gt 0 ]]; then
    avg=$((elapsed / done))
    remaining=$((avg * (total - done)))
  else
    remaining=0
  fi

  bar_len=28
  filled=$((percent * bar_len / 100))
  empty=$((bar_len - filled))
  progress_out "\r[%.*s%.*s] %3d%% (%d/%d) elapsed %s ETA %s - %s" \
    "${filled}" "############################" \
    "${empty}" "----------------------------" \
    "${percent}" "${done}" "${total}" "$(fmt_mmss "${elapsed}")" "$(fmt_mmss "${remaining}")" "${status}"
}

progress_finish_line() {
  progress_out "\n"
}

run_step() { # label, cmd...
  local label="$1"
  shift

  if [[ "${PROGRESS_TOTAL:-0}" -gt 0 ]]; then
    progress_render "Running: ${label}" "${PROGRESS_DONE}"
  fi

  "$@"

  if [[ "${PROGRESS_TOTAL:-0}" -gt 0 ]]; then
    PROGRESS_DONE=$((PROGRESS_DONE + 1))
    progress_render "Done: ${label}" "${PROGRESS_DONE}"
    progress_finish_line
  fi
}

show_splashscreen() {
  local void_green reset underline
  void_green="\033[38;2;70;185;54m"
  reset="\033[0m"
  underline="\033[4m"

  printf "\n${void_green}"
  cat <<'EOF'
 __     ______ ___ ____    ___ _   _ ____ _____  _    _     _     _____ ____
 \ \   / / _ \_ _|  _ \  |_ _| \ | / ___|_   _|/ \  | |   | |   | ____|  _ \
  \ \ / / | | | || | | |  | ||  \| \___ \ | | / _ \ | |   | |   |  _| | |_) |
   \ V /| |_| | || |_| |  | || |\  |___) || |/ ___ \| |___| |___| |___|  _ <
    \_/  \___/___|____/  |___|_| \_|____/ |_/_/   \_\_____|_____|_____|_| \_\
EOF
  printf "${underline}Enter the void...${reset}\n\n"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run as root (e.g. sudo bash $0)."
  fi
}

read_default() { # prompt default -> echo value
  local prompt="$1" default="$2" input=""
  read -r -p "${prompt} [${default}]: " input || true
  if [[ -z "${input}" ]]; then printf "%s" "${default}"; else printf "%s" "${input}"; fi
}

yes_no() { # prompt default(y/n). return 0 yes, 1 no
  local prompt="$1" def="$2" dshow="y/N"
  [[ "${def}" == "y" ]] && dshow="Y/n"
  while true; do
    local a=""
    read -r -p "${prompt} [${dshow}]: " a || true
    a="${a:-$def}"
    case "${a,,}" in
      y|yes|j|ja) return 0 ;;
      n|no|nein) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

xbps_sync() {
  info "Syncing XBPS indexes..."
  xbps-install -Sy >/dev/null
}

xbps_install() {
  info "Installing: $*"
  xbps-install -y "$@"
}

xbps_pkg_available() { xbps-query -R "$1" >/dev/null 2>&1; }

xbps_install_if_available() { # pkgs...
  local to_install=()
  local p
  for p in "$@"; do
    if xbps_pkg_available "$p"; then
      to_install+=("$p")
    else
      warn "Package not found (skipping): $p"
    fi
  done

  if ((${#to_install[@]})); then
    xbps_install "${to_install[@]}"
  fi
}

xbps_install_first_available() { # label, pkg1, pkg2...
  local label="$1"
  shift
  local p
  for p in "$@"; do
    if xbps_pkg_available "$p"; then
      xbps_install "$p"
      return 0
    fi
  done
  warn "No package found for ${label}. Tried: $*"
  return 1
}

ensure_waybar_launcher() {
  local path="/usr/local/bin/Waybar"
  safe_mkdir "$(dirname "${path}")"
  cat > "${path}" <<'EOF'
#!/usr/bin/env sh
set -eu
if command -v Waybar >/dev/null 2>&1; then
  exec "$(command -v Waybar)" "$@"
fi
if command -v waybar >/dev/null 2>&1; then
  exec "$(command -v waybar)" "$@"
fi
echo "Waybar/waybar not found." >&2
exit 127
EOF
  chmod 0755 "${path}"
}

enable_void_extra_repo() {
  # Encoded14/void-extra (prebuilt repo)
  # Not affiliated with Void Linux. Use at your own risk.
  local arch libc repo_arch conf_path
  arch="$(detect_arch)"
  libc="$(detect_libc_flavor)"

  case "${arch}:${libc}" in
    x86_64:gnu) repo_arch="x86_64" ;;
    x86_64:musl) repo_arch="x86_64-musl" ;;
    aarch64:gnu) repo_arch="aarch64" ;;
    aarch64:musl) repo_arch="aarch64-musl" ;;
    *)
      warn "void-extra repo does not provide prebuilt packages for ${arch} (${libc}). Hyprland install will be skipped."
      return 0
      ;;
  esac

  conf_path="/etc/xbps.d/20-repository-extra.conf"
  if [[ -f "${conf_path}" ]] && grep -q "raw.githubusercontent.com/Encoded14/void-extra/repository-" "${conf_path}" 2>/dev/null; then
    info "void-extra repo already configured (${conf_path})."
  else
    info "Configuring void-extra prebuilt repo (${repo_arch})..."
    safe_mkdir "$(dirname "${conf_path}")"
    printf "repository=https://raw.githubusercontent.com/Encoded14/void-extra/repository-%s\n" "${repo_arch}" >"${conf_path}"
  fi

  info "Refreshing repositories (you may be prompted to accept a fingerprint)..."
  xbps-install -S >/dev/null || true
}

install_hyprland_experimental() {
  info "Installing Hyprland (EXPERIMENTAL/BETA) from void-extra..."
  enable_void_extra_repo
  if xbps_pkg_available hyprland; then
    xbps_install hyprland
  else
    warn "hyprland package not found even after enabling void-extra. Skipping Hyprland install."
  fi

  # Useful Wayland basics; install only if available.
  xbps_install_if_available xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-wlr xwayland
}

enable_service() { # /etc/sv/name -> /var/service/name
  local name="$1"
  local src="/etc/sv/${name}"
  local dst="/var/service/${name}"
  if [[ ! -d "${src}" ]]; then
    warn "Service ${name} not found at ${src} (package might not provide a runit service)."
    return 0
  fi
  if [[ -L "${dst}" || -d "${dst}" ]]; then
    info "Service enabled: ${name}"
    return 0
  fi
  ln -s "${src}" "${dst}"
  info "Enabled service: ${name}"
}

ensure_user() {
  local u="$1"
  id "$u" >/dev/null 2>&1 || die "User does not exist: ${u}"
}

safe_mkdir() { mkdir -p "$1"; }

# ---------------- environment checks ----------------
detect_void() {
  [[ -f /etc/os-release ]] || die "/etc/os-release missing"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "void" ]] || warn "This does not look like Void Linux (ID=${ID:-unknown}). Continuing anyway."
}

detect_arch() {
  local a
  a="$(uname -m)"
  case "$a" in
    x86_64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "$a" ;;
  esac
}

detect_libc_flavor() { # -> gnu|musl
  if have_cmd ldd && ldd --version 2>&1 | grep -qi musl; then
    echo "musl"
  else
    echo "gnu"
  fi
}

# ---------------- prompts ----------------
choose_target_user() {
  local u
  u="$(read_default "Enter the main (non-root) username to configure" "${SUDO_USER:-}")"
  [[ -n "$u" ]] || die "No user provided."
  ensure_user "$u"
  echo "$u"
}

choose_session_stack() {
  local prompt=$'\nSeat management:\n  1) elogind (recommended, broad compatibility, KDE/SDDM friendly)\n  2) seatd  (lean, good for Wayland compositors)\nChoose'
  local c
  c="$(read_default "${prompt}" "1")"
  case "$c" in
    2) echo "seatd" ;;
    *) echo "elogind" ;;
  esac
}

choose_de() {
  local prompt=$'\nDesktop/WM selection:\n  1) i3 (default, X11)\n  2) KDE Plasma (X11/Wayland, heavier)\n  3) river (Wayland)\n  4) dwm (X11, minimal)\n  5) niri (Wayland)\n  6) Hyprland (Wayland, EXPERIMENTAL/BETA via void-extra)\n  7) sway (Wayland)\n  8) awesome (X11)\n  9) herbstluftwm (X11)\nChoose'
  local c
  c="$(read_default "${prompt}" "1")"
  case "$c" in
    2) echo "plasma" ;;
    3) echo "river" ;;
    4) echo "dwm" ;;
    5) echo "niri" ;;
    6) echo "hyprland" ;;
    7) echo "sway" ;;
    8) echo "awesome" ;;
    9) echo "herbstluftwm" ;;
    *) echo "i3" ;;
  esac
}

choose_login_manager() {
  local prompt=$'\nLogin manager:\n  1) sddm (default, recommended for KDE and fine for others)\n  2) lightdm (GTK greeter)\n  3) greetd + tuigreet (simple, good for Wayland WMs)\n  4) none (startx/tty)\nChoose'
  local c
  c="$(read_default "${prompt}" "1")"
  case "$c" in
    2) echo "lightdm" ;;
    3) echo "greetd" ;;
    4) echo "none" ;;
    *) echo "sddm" ;;
  esac
}

normalize_stack_for_login_manager() { # seatstack, lm -> echo seatstack
  local seatstack="$1" lm="$2"
  if [[ "$lm" == "sddm" && "$seatstack" != "elogind" ]]; then
    warn "SDDM with seatd commonly fails on Void (VT/xauth). Switching seat stack to elogind."
    seatstack="elogind"
  fi
  echo "$seatstack"
}

choose_browser() {
  local prompt=$'\nBrowser selection:\n  1) Firefox (default)\n  2) Chromium\n  3) Brave\n  4) Librewolf (if available in repos)\nChoose'
  local c
  c="$(read_default "${prompt}" "1")"
  case "$c" in
    2) echo "chromium" ;;
    3) echo "brave-browser" ;;
    4) echo "librewolf" ;;
    *) echo "firefox" ;;
  esac
}

choose_gpu() {
  local prompt=$'\nGPU selection (for drivers):\n  1) auto-detect (default)\n  2) NVIDIA (proprietary)\n  3) AMD (Mesa + Vulkan; optional AMDVLK)\n  4) Intel (Mesa)\nChoose'
  local c
  c="$(read_default "${prompt}" "1")"
  case "$c" in
    2) echo "nvidia" ;;
    3) echo "amd" ;;
    4) echo "intel" ;;
    *) echo "auto" ;;
  esac
}

# ---------------- repo setup ----------------
enable_void_repos() {
  info "Enabling Void repos (nonfree + multilib where applicable)..."

  # These metapackages drop repo files into /etc/xbps.d/
  # On x86_64, multilib is supported. On other arches, it may not exist.
  local arch
  arch="$(detect_arch)"

  xbps_sync

  # nonfree
  if xbps-query -R void-repo-nonfree >/dev/null 2>&1; then
    xbps_install void-repo-nonfree
  else
    warn "void-repo-nonfree not found in repos. NVIDIA proprietary may not be installable."
  fi

  if [[ "$arch" == "x86_64" ]]; then
    if xbps-query -R void-repo-multilib >/dev/null 2>&1; then
      xbps_install void-repo-multilib
    else
      warn "void-repo-multilib not found."
    fi
    if xbps-query -R void-repo-multilib-nonfree >/dev/null 2>&1; then
      xbps_install void-repo-multilib-nonfree
    else
      warn "void-repo-multilib-nonfree not found."
    fi
  else
    warn "Architecture ${arch}: multilib likely not available. Skipping multilib repos."
  fi

  xbps_sync
}

# ---------------- base services ----------------
install_core_services() {
  local seatstack="$1"
  info "Installing core services: dbus + ${seatstack} + polkit"
  xbps_install dbus polkit

  enable_service dbus

  if [[ "$seatstack" == "elogind" ]]; then
    xbps_install elogind
    enable_service elogind
  else
    xbps_install seatd
    enable_service seatd
  fi
}

# ---------------- audio/bluetooth ----------------
install_pipewire_bluetooth() {
  info "Installing PipeWire + WirePlumber + Bluetooth stack..."
  xbps_install pipewire wireplumber alsa-utils

  # Bluetooth + GUI manager
  xbps_install bluez blueman

  # PipeWire bluetooth (SPA)
  # Some Void repos name it "libspa-bluetooth"; if not, it may be in pipewire package.
  if xbps-query -R libspa-bluetooth >/dev/null 2>&1; then
    xbps_install libspa-bluetooth
  else
    warn "libspa-bluetooth package not found; Bluetooth audio may still work if included in PipeWire build."
  fi

  # Enable bluetooth daemon
  enable_service bluetoothd
}

# ---------------- flatpak ----------------
install_flatpak() {
  info "Installing Flatpak and enabling Flathub..."
  xbps_install flatpak

  # Add flathub if not present
  if ! flatpak remote-list --system 2>/dev/null | awk '{print $1}' | grep -qx flathub; then
    flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    info "Flathub remote added."
  else
    info "Flathub already present."
  fi
}

# ---------------- dev tools ----------------
install_dev_tools() {
  info "Installing development tools..."
  # base-devel includes gcc, make, etc.
  xbps_install base-devel git curl wget ca-certificates pkg-config cmake ninja python3 python3-pip go rust cargo gdb strace
  xbps_install_if_available neovim python3-gobject cairo cairo-devel
}

install_fastfetch() {
  info "Installing fastfetch (for the vibes)..."
  if xbps-query -R fastfetch >/dev/null 2>&1; then
    xbps_install fastfetch
  else
    warn "fastfetch package not found in your repos; skipping."
  fi
}

install_fonts() {
  info "Installing common fonts..."
  xbps_install_if_available fontconfig

  # Baseline choice: dejavu-fonts-ttf OR xorg-fonts.
  if xbps_pkg_available dejavu-fonts-ttf; then
    xbps_install dejavu-fonts-ttf
  elif xbps_pkg_available xorg-fonts; then
    xbps_install xorg-fonts
  else
    warn "No baseline font packages found (dejavu-fonts-ttf / xorg-fonts). Skipping font installation."
    return 0
  fi

  # Modern/common additions (install if present).
  xbps_install_if_available noto-fonts-ttf noto-fonts-cjk noto-fonts-emoji nerd-fonts nerd-fonts-ttf

  if have_cmd xbps-reconfigure; then
    xbps-reconfigure -f fontconfig >/dev/null 2>&1 || true
  fi
}

install_sample_wallpaper() {
  info "Installing sample wallpaper to ${WALLPAPER_SYSTEM_PATH}..."
  if [[ ! -f "${WALLPAPER_REPO_PATH}" ]]; then
    warn "Sample wallpaper not found at ${WALLPAPER_REPO_PATH}. Skipping wallpaper install."
    return 0
  fi
  safe_mkdir "$(dirname "${WALLPAPER_SYSTEM_PATH}")"
  cp -f "${WALLPAPER_REPO_PATH}" "${WALLPAPER_SYSTEM_PATH}"
  chmod 0644 "${WALLPAPER_SYSTEM_PATH}" || true
}

session_kind_for_de() { # de -> x11|wayland
  case "$1" in
    river|niri|hyprland|sway) echo "wayland" ;;
    *) echo "x11" ;;
  esac
}

choose_launcher() { # session_kind -> launcher id
  local kind="$1"
  if [[ "$kind" == "wayland" ]]; then
    local prompt=$'\nApp launcher (Wayland):\n  1) wofi   (recommended)\n  2) fuzzel\n  3) none\nChoose'
    local c
    c="$(read_default "${prompt}" "1")"
    case "$c" in
      2) echo "fuzzel" ;;
      3) echo "none" ;;
      *) echo "wofi" ;;
    esac
  else
    local prompt=$'\nApp launcher (X11):\n  1) rofi   (recommended)\n  2) dmenu  (already installed on i3/dwm)\n  3) none\nChoose'
    local c
    c="$(read_default "${prompt}" "1")"
    case "$c" in
      2) echo "dmenu" ;;
      3) echo "none" ;;
      *) echo "rofi" ;;
    esac
  fi
}

launcher_cmd_for() { # launcher id -> command string
  case "$1" in
    rofi) echo "rofi -show drun" ;;
    dmenu) echo "dmenu_run" ;;
    fuzzel) echo "fuzzel" ;;
    wofi) echo "wofi --show drun" ;;
    none|*) echo "" ;;
  esac
}

install_launcher() { # launcher id
  local l="$1"
  case "$l" in
    rofi|fuzzel|wofi)
      xbps_install_if_available "$l"
      ;;
    dmenu)
      xbps_install_if_available dmenu
      ;;
    none|"")
      ;;
    *)
      warn "Unknown launcher choice: ${l} (skipping)"
      ;;
  esac
}

choose_wallpaper_manager() { # session_kind -> manager id
  local kind="$1"
  if [[ "$kind" == "wayland" ]]; then
    local prompt=$'\nWallpaper manager (Wayland GUI):\n  1) azote (recommended)\n  2) waypaper (pipx)\n  3) none\nChoose'
    local c
    c="$(read_default "${prompt}" "1")"
    case "$c" in
      2) echo "waypaper" ;;
      3) echo "none" ;;
      *) echo "azote" ;;
    esac
  else
    local prompt=$'\nWallpaper manager (X11 GUI):\n  1) nitrogen (recommended)\n  2) waypaper (pipx)\n  3) none\nChoose'
    local c
    c="$(read_default "${prompt}" "1")"
    case "$c" in
      2) echo "waypaper" ;;
      3) echo "none" ;;
      *) echo "nitrogen" ;;
    esac
  fi
}

choose_waypaper_backend() { # session_kind -> backend id
  local kind="$1"
  if [[ "$kind" == "wayland" ]]; then
    local prompt=$'\nWaypaper backend (Wayland):\n  1) swaybg (stable default)\n  2) awww (or swww package fallback)\n  3) hyprpaper\n  4) mpvpaper\n  5) wallutils\nChoose'
    local c
    c="$(read_default "${prompt}" "1")"
    case "$c" in
      2) echo "awww" ;;
      3) echo "hyprpaper" ;;
      4) echo "mpvpaper" ;;
      5) echo "wallutils" ;;
      *) echo "swaybg" ;;
    esac
  else
    local prompt=$'\nWaypaper backend (X11):\n  1) feh (stable default)\n  2) xwallpaper\n  3) wallutils\n  4) mpvpaper\nChoose'
    local c
    c="$(read_default "${prompt}" "1")"
    case "$c" in
      2) echo "xwallpaper" ;;
      3) echo "wallutils" ;;
      4) echo "mpvpaper" ;;
      *) echo "feh" ;;
    esac
  fi
}

install_waypaper_backend() { # backend id, session_kind
  local backend="$1" kind="$2"
  case "$backend" in
    awww)
      if ! xbps_install_first_available "Waypaper backend awww/swww" awww swww; then
        if [[ "$kind" == "wayland" ]]; then
          warn "Falling back to swaybg backend for Waypaper."
          xbps_install_if_available swaybg
        else
          warn "Falling back to feh backend for Waypaper."
          xbps_install_if_available feh
        fi
      fi
      ;;
    swaybg|xwallpaper|feh|wallutils|hyprpaper|mpvpaper)
      xbps_install_if_available "${backend}"
      ;;
    *)
      warn "Unknown Waypaper backend: ${backend}. Installing a safe default."
      if [[ "$kind" == "wayland" ]]; then
        xbps_install_if_available swaybg
      else
        xbps_install_if_available feh
      fi
      ;;
  esac
}

install_pipx_for_waypaper() {
  if have_cmd pipx; then
    info "pipx already installed."
    return 0
  fi

  info "Installing pipx for Waypaper..."
  if xbps_pkg_available pipx; then
    xbps_install pipx
  elif xbps_pkg_available python3-pipx; then
    xbps_install python3-pipx
  else
    warn "No pipx package found in XBPS. Falling back to python3 -m pip install pipx."
    xbps_install python3 python3-pip
    python3 -m pip install --upgrade pipx
    if [[ -x /root/.local/bin/pipx ]] && [[ ! -x /usr/local/bin/pipx ]]; then
      ln -s /root/.local/bin/pipx /usr/local/bin/pipx || true
    fi
  fi

  have_cmd pipx || die "pipx installation failed; cannot install Waypaper."
}

install_waypaper_with_pipx() {
  if pipx install --help 2>/dev/null | grep -q -- "--global"; then
    if pipx list --global 2>/dev/null | grep -q "package waypaper"; then
      info "Waypaper already installed via pipx (global). Upgrading..."
      pipx upgrade --global waypaper || true
    else
      pipx install --global waypaper
    fi
  else
    local -a pipx_env=(PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin PIPX_MAN_DIR=/usr/local/share/man)
    if env "${pipx_env[@]}" pipx list 2>/dev/null | grep -q "package waypaper"; then
      info "Waypaper already installed via pipx. Upgrading..."
      env "${pipx_env[@]}" pipx upgrade waypaper || true
    else
      env "${pipx_env[@]}" pipx install waypaper
    fi
  fi
}

install_waypaper_manager() { # session_kind, backend
  local kind="$1" backend="$2"
  info "Installing Waypaper and dependencies..."

  install_waypaper_backend "${backend}" "${kind}"

  xbps_install_first_available "Python GObject bindings" python3-gobject python3-gi python-gobject || true
  xbps_install_first_available "python-imageio" python3-imageio python-imageio || true
  xbps_install_first_available "python-imageio-ffmpeg" python3-imageio-ffmpeg python-imageio-ffmpeg python3-imageio_ffmpeg python-imageio_ffmpeg || true
  xbps_install_first_available "python-screeninfo" python3-screeninfo python-screeninfo || true
  xbps_install_first_available "python-platformdirs" python3-platformdirs python-platformdirs || true
  xbps_install_if_available python3 python3-pip

  install_pipx_for_waypaper
  install_waypaper_with_pipx
}

install_wallpaper_manager() { # manager id, session_kind, waypaper_backend
  local manager="$1" kind="${2:-}" waypaper_backend="${3:-}"
  case "${manager}" in
    nitrogen|azote)
      xbps_install_if_available "${manager}"
      ;;
    waypaper)
      install_waypaper_manager "${kind}" "${waypaper_backend}"
      ;;
    none|"")
      ;;
    *)
      warn "Unknown wallpaper manager choice: ${manager} (skipping)"
      ;;
  esac
}

choose_file_manager() { # de, session_kind -> pkg name or none
  local de="$1" kind="$2"
  if [[ "$de" == "plasma" ]]; then
    local prompt=$'\nFile manager:\n  1) dolphin (recommended for KDE)\n  2) nemo\n  3) thunar\n  4) pcmanfm\n  5) none\nChoose'
    local c
    c="$(read_default "${prompt}" "1")"
    case "$c" in
      2) echo "nemo" ;;
      3) echo "thunar" ;;
      4) echo "pcmanfm" ;;
      5) echo "none" ;;
      *) echo "dolphin" ;;
    esac
    return 0
  fi

  if [[ "$kind" == "wayland" ]]; then
    local prompt=$'\nFile manager:\n  1) thunar (recommended)\n  2) nemo\n  3) pcmanfm\n  4) dolphin\n  5) none\nChoose'
    local c
    c="$(read_default "${prompt}" "1")"
    case "$c" in
      2) echo "nemo" ;;
      3) echo "pcmanfm" ;;
      4) echo "dolphin" ;;
      5) echo "none" ;;
      *) echo "thunar" ;;
    esac
  else
    local prompt=$'\nFile manager:\n  1) nemo (recommended)\n  2) thunar\n  3) pcmanfm\n  4) dolphin\n  5) none\nChoose'
    local c
    c="$(read_default "${prompt}" "1")"
    case "$c" in
      2) echo "thunar" ;;
      3) echo "pcmanfm" ;;
      4) echo "dolphin" ;;
      5) echo "none" ;;
      *) echo "nemo" ;;
    esac
  fi
}

install_file_manager() { # pkg
  local fm="$1"
  case "$fm" in
    nemo|thunar|pcmanfm|dolphin)
      xbps_install_if_available "$fm"
      ;;
    none|"")
      ;;
    *)
      warn "Unknown file manager choice: ${fm} (skipping)"
      ;;
  esac
}

# ---------------- gaming / 32-bit ----------------
install_gaming_multilib() {
  local arch
  arch="$(detect_arch)"
  if [[ "$arch" != "x86_64" ]]; then
    warn "Non-x86_64 architecture; skipping 32-bit gaming libs."
    return 0
  fi

  info "Installing common gaming-related packages and 32-bit libs..."
  # Common Vulkan/OpenGL libs (64-bit)
  xbps_install mesa mesa-dri vulkan-loader

  # 32-bit counterparts (package names may vary slightly by repo state)
  for p in mesa-dri-32bit vulkan-loader-32bit libstdc++-32bit; do
    if xbps-query -R "$p" >/dev/null 2>&1; then
      xbps_install "$p"
    else
      warn "Package not found (skipping): $p"
    fi
  done

  # Optional Steam
  if xbps-query -R steam >/dev/null 2>&1; then
    if yes_no "Install Steam?" "y"; then
      xbps_install steam
    fi
  else
    warn "steam package not found in your repos."
  fi
}

# ---------------- GPU drivers ----------------
auto_detect_gpu_vendor() {
  # Try to ensure lspci exists on Void; on non-Void, just skip GPU install.
  if ! have_cmd lspci; then
    if have_cmd xbps-install; then
      xbps_install pciutils || true
    fi
  fi

  if ! have_cmd lspci; then
    warn "Could not detect GPU (no lspci available). GPU drivers will NOT be installed; please install them manually."
    echo "none"
    return 0
  fi

  local out
  out="$(lspci -nn | grep -Ei 'vga|3d|display' || true)"
  if echo "$out" | grep -qi nvidia; then
    echo "nvidia"
  elif echo "$out" | grep -qi 'amd|ati'; then
    echo "amd"
  elif echo "$out" | grep -qi intel; then
    echo "intel"
  elif [[ -z "$out" ]]; then
    warn "No GPU devices detected via lspci. GPU drivers will NOT be installed; please install them manually."
    echo "none"
  else
    warn "GPU devices detected but vendor could not be classified. GPU drivers will NOT be installed; please install them manually."
    echo "none"
  fi
}

install_gpu_drivers() {
  local choice="$1"
  local vendor="$choice"
  if [[ "$choice" == "auto" ]]; then
    vendor="$(auto_detect_gpu_vendor)"
    info "Auto-detected GPU vendor: ${vendor}"
  fi

  case "$vendor" in
    nvidia)
      info "Installing NVIDIA proprietary driver stack..."
      # Kernel headers needed for dkms modules in many setups
      xbps_install linux-headers

      # Preferred package set on Void commonly includes nvidia-dkms + nvidia
      # Fallback if nvidia-dkms doesn't exist.
      if xbps-query -R nvidia-dkms >/dev/null 2>&1; then
        xbps_install nvidia-dkms nvidia
      else
        xbps_install nvidia
        warn "nvidia-dkms not found; kernel module packaging may differ on your repo snapshot."
      fi

      # 32-bit libs for Steam/Wine if available
      for p in nvidia-libs-32bit; do
        if xbps-query -R "$p" >/dev/null 2>&1; then
          xbps_install "$p"
        else
          warn "Package not found (skipping): $p"
        fi
      done
      ;;
    amd)
      info "Installing AMD Mesa/Vulkan stack..."
      xbps_install mesa mesa-dri vulkan-loader
      # Prefer RADV (vulkan-radeon) if available
      if xbps-query -R vulkan-radeon >/dev/null 2>&1; then
        xbps_install vulkan-radeon
      fi
      if yes_no "Install AMDVLK (optional alternative Vulkan driver)?" "n"; then
        if xbps-query -R amdvlk >/dev/null 2>&1; then
          xbps_install amdvlk
        else
          warn "amdvlk not found in repos."
        fi
      fi
      ;;
    intel)
      info "Installing Intel Mesa/Vulkan stack..."
      xbps_install mesa mesa-dri vulkan-loader
      ;;
    none|"")
      warn "Skipping GPU driver installation because no suitable GPU was detected. You will need to install drivers manually."
      ;;
    *)
      warn "Unknown GPU vendor (${vendor}). Skipping GPU driver installation. You will need to install drivers manually."
      ;;
  esac
}

# ---------------- login managers ----------------
install_login_manager() {
  local lm="$1"
  case "$lm" in
    sddm)
      info "Installing SDDM..."
      # SDDM on Void uses an X11 greeter by default; make sure Xorg + xauth are present.
      xbps_install sddm xorg-minimal xauth
      safe_mkdir /etc/sddm.conf.d
      cat > /etc/sddm.conf.d/10-void-auto-setup.conf <<'EOF'
[General]
DisplayServer=x11
EOF
      if id sddm >/dev/null 2>&1; then
        safe_mkdir /var/lib/sddm
        chown sddm:sddm /var/lib/sddm || true
      fi
      enable_service sddm
      ;;
    lightdm)
      info "Installing LightDM..."
      xbps_install lightdm lightdm-gtk3-greeter
      enable_service lightdm
      ;;
    greetd)
      info "Installing greetd + tuigreet..."
      xbps_install greetd tuigreet
      enable_service greetd
      ;;
    none)
      info "No login manager selected."
      ;;
  esac
}

# ---------------- desktop / wm installs ----------------
install_x11_base() {
  xbps_install xorg-minimal xinit xauth xsetroot xrandr xdg-utils xdg-user-dirs polybar
}

install_wayland_base() {
  xbps_install wayland wayland-protocols xdg-utils xdg-user-dirs
  xbps_install_first_available "Waybar" Waybar waybar || true
  ensure_waybar_launcher
}

install_de() {
  local de="$1"
  case "$de" in
    i3)
      info "Installing i3 environment (X11)..."
      install_x11_base
      xbps_install i3 i3status i3lock dmenu picom feh alacritty
      ;;
    plasma)
      info "Installing KDE Plasma..."
      install_x11_base
      # Plasma meta packages vary; try a sensible set
      if xbps-query -R kde5 >/dev/null 2>&1; then
        xbps_install kde5
      else
        xbps_install plasma-desktop konsole dolphin kdegraphics-thumbnailers
      fi
      ;;
    dwm)
      info "Installing dwm (X11)..."
      install_x11_base
      xbps_install dwm st dmenu feh picom
      ;;
    awesome)
      info "Installing awesome WM (X11)..."
      install_x11_base
      xbps_install awesome feh picom alacritty
      ;;
    herbstluftwm)
      info "Installing herbstluftwm (X11)..."
      install_x11_base
      xbps_install herbstluftwm dmenu feh picom alacritty
      ;;
    river)
      info "Installing river (Wayland)..."
      install_wayland_base
      xbps_install river foot swaybg grim slurp wl-clipboard
      ;;
    niri)
      info "Installing niri (Wayland)..."
      install_wayland_base
      # Package name can differ; attempt "niri"
      if xbps-query -R niri >/dev/null 2>&1; then
        xbps_install niri
      else
        warn "niri package not found in repos. You may need to build it from source."
      fi
      xbps_install foot swaybg grim slurp wl-clipboard
      ;;
    hyprland)
      info "Installing Hyprland base dependencies (Wayland)..."
      install_wayland_base
      xbps_install_if_available foot swaybg grim slurp wl-clipboard
      ;;
    sway)
      info "Installing sway (Wayland)..."
      install_wayland_base
      xbps_install sway foot swaybg grim slurp wl-clipboard
      ;;
  esac
}

# ---------------- user configuration ----------------
as_user() { # user cmd...
  local u="$1"; shift
  sudo -u "$u" -H bash -lc "$*"
}

ensure_groups_for_seat_stack() {
  local seatstack="$1" u="$2"
  # For seatd, user often needs "seat" group access. Void uses 'seat' group for seatd.
  if [[ "$seatstack" == "seatd" ]]; then
    if getent group seat >/dev/null 2>&1; then
      usermod -aG seat "$u" || true
      info "Added ${u} to group 'seat' (seatd access)."
    else
      warn "Group 'seat' not found. seatd access may require manual adjustment."
    fi
  fi
  # Common groups for audio/video/input
  for g in audio video input; do
    if getent group "$g" >/dev/null 2>&1; then
      usermod -aG "$g" "$u" || true
    fi
  done
}

setup_common_user_bits() {
  local u="$1"
  info "Setting up common user directories and autostart bits for ${u}..."
  as_user "$u" "xdg-user-dirs-update || true"

  # Ensure pipewire/wireplumber start from session (since no systemd user units)
  safe_mkdir "/home/${u}/.config"
  safe_mkdir "/home/${u}/.config/autostart"

  cat > "/home/${u}/.config/autostart/pipewire.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Exec=pipewire
X-GNOME-Autostart-enabled=true
EOF

  cat > "/home/${u}/.config/autostart/wireplumber.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=WirePlumber
Exec=wireplumber
X-GNOME-Autostart-enabled=true
EOF

  chown -R "${u}:${u}" "/home/${u}/.config/autostart"
}

setup_waypaper_restore_autostart() {
  local u="$1"
  info "Adding Waypaper restore autostart for ${u}..."
  safe_mkdir "/home/${u}/.config/autostart"
  cat > "/home/${u}/.config/autostart/waypaper-restore.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Waypaper Restore
Exec=waypaper --restore
TryExec=waypaper
X-GNOME-Autostart-enabled=true
EOF
  chown "${u}:${u}" "/home/${u}/.config/autostart/waypaper-restore.desktop"
}

setup_i3_config() {
  local u="$1" launcher_cmd="${2:-dmenu_run}" wallpaper_path="${3:-${WALLPAPER_SYSTEM_PATH}}"
  info "Generating i3 config for ${u}..."
  safe_mkdir "/home/${u}/.config/i3"
  safe_mkdir "/home/${u}/.config/i3status"

  cat > "/home/${u}/.config/i3/config" <<'EOF'
# i3 config (generated)
set $mod Mod4
font pango:monospace 10

# Terminal and launcher
bindsym $mod+Return exec alacritty
EOF
  if [[ -n "${launcher_cmd}" ]]; then
    printf "bindsym \$mod+d exec --no-startup-id %s\n\n" "${launcher_cmd}" >>"/home/${u}/.config/i3/config"
  fi
  cat >> "/home/${u}/.config/i3/config" <<'EOF'

# Basics
bindsym $mod+Shift+q kill
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec "i3-nagbar -t warning -m 'Exit i3?' -b 'Yes' 'i3-msg exit'"

# Focus/move
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right

# Layout
bindsym $mod+v split v
bindsym $mod+b split h
bindsym $mod+f fullscreen toggle
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split

# Workspaces
set $ws1 "1"
set $ws2 "2"
set $ws3 "3"
set $ws4 "4"
set $ws5 "5"
bindsym $mod+1 workspace $ws1
bindsym $mod+2 workspace $ws2
bindsym $mod+3 workspace $ws3
bindsym $mod+4 workspace $ws4
bindsym $mod+5 workspace $ws5
bindsym $mod+Shift+1 move container to workspace $ws1; workspace $ws1
bindsym $mod+Shift+2 move container to workspace $ws2; workspace $ws2
bindsym $mod+Shift+3 move container to workspace $ws3; workspace $ws3
bindsym $mod+Shift+4 move container to workspace $ws4; workspace $ws4
bindsym $mod+Shift+5 move container to workspace $ws5; workspace $ws5

# Status bar
bar {
  status_command i3status
}

# Compositor + wallpaper
exec --no-startup-id picom
EOF
  printf "exec --no-startup-id feh --bg-scale %q 2>/dev/null || true\n\n" "${wallpaper_path}" >>"/home/${u}/.config/i3/config"
  cat >> "/home/${u}/.config/i3/config" <<'EOF'

# Audio (PipeWire)
exec --no-startup-id pipewire
exec --no-startup-id wireplumber

# Bluetooth tray (optional)
exec --no-startup-id blueman-applet
EOF

  cat > "/home/${u}/.config/i3status/config" <<'EOF'
general {
  colors = true
  interval = 5
}
order += "disk /"
order += "wireless _first_"
order += "ethernet _first_"
order += "battery all"
order += "volume master"
order += "tztime local"

disk "/" { format = "Disk %avail" }
wireless "_first_" { format_up = "W: %quality at %essid %ip" format_down = "W: down" }
ethernet "_first_" { format_up = "E: %ip" format_down = "E: down" }
battery "all" { format = "%status %percentage %remaining" }
volume "master" { format = "Vol %volume" }
tztime "local" { format = "%Y-%m-%d %H:%M" }
EOF

  chown -R "${u}:${u}" "/home/${u}/.config/i3" "/home/${u}/.config/i3status"
}

setup_xinitrc_for_x11() {
  local u="$1" session_cmd="$2" wallpaper_path="${3:-${WALLPAPER_SYSTEM_PATH}}"
  info "Generating ~/.xinitrc for ${u} (X11)..."
  cat > "/home/${u}/.xinitrc" <<EOF
#!/usr/bin/env sh
# generated
export XDG_CURRENT_DESKTOP="${session_cmd}"
export XDG_SESSION_TYPE="x11"
command -v feh >/dev/null 2>&1 && feh --bg-scale "${wallpaper_path}" >/dev/null 2>&1 || true
exec ${session_cmd}
EOF
  chmod 0755 "/home/${u}/.xinitrc"
  chown "${u}:${u}" "/home/${u}/.xinitrc"
}

setup_dwm_config() {
  local u="$1" wallpaper_path="${2:-${WALLPAPER_SYSTEM_PATH}}"
  info "dwm uses built-in defaults. Providing a usable ~/.xinitrc..."
  setup_xinitrc_for_x11 "$u" "dwm" "${wallpaper_path}"
  # Basic wallpaper + compositor via .xprofile
  cat > "/home/${u}/.xprofile" <<'EOF'
# generated
(picom &) >/dev/null 2>&1 || true
EOF
  printf "(feh --bg-scale %q &) >/dev/null 2>&1 || true\n" "${wallpaper_path}" >>"/home/${u}/.xprofile"
  chown "${u}:${u}" "/home/${u}/.xprofile"
}

setup_awesome_config() {
  local u="$1" wallpaper_path="${2:-${WALLPAPER_SYSTEM_PATH}}"
  info "Configuring awesome for ${u}..."
  safe_mkdir "/home/${u}/.config/awesome"
  if [[ -f /etc/xdg/awesome/rc.lua ]]; then
    cp -f /etc/xdg/awesome/rc.lua "/home/${u}/.config/awesome/rc.lua"
  else
    warn "/etc/xdg/awesome/rc.lua not found. Awesome will use packaged defaults if available."
  fi

  cat > "/home/${u}/.xprofile" <<'EOF'
# generated
(picom &) >/dev/null 2>&1 || true
EOF
  printf "(feh --bg-scale %q &) >/dev/null 2>&1 || true\n" "${wallpaper_path}" >>"/home/${u}/.xprofile"
  chown -R "${u}:${u}" "/home/${u}/.config/awesome" "/home/${u}/.xprofile"

  setup_xinitrc_for_x11 "$u" "awesome" "${wallpaper_path}"
}

setup_herbstluftwm_config() {
  local u="$1" launcher_cmd="${2:-dmenu_run}" wallpaper_path="${3:-${WALLPAPER_SYSTEM_PATH}}"
  info "Generating herbstluftwm config for ${u}..."
  safe_mkdir "/home/${u}/.config/herbstluftwm"
  cat > "/home/${u}/.config/herbstluftwm/autostart" <<'EOF'
#!/usr/bin/env bash
set -eu

hc() { herbstclient "$@"; }

# basic reset/defaults
hc emit_hook reload
hc set frame_border_width 2
hc set window_border_width 2
hc set frame_gap 8
hc set smart_frame_surroundings on
hc set smart_window_surroundings on
hc set mouse_recenter_gap 0

# tags/workspaces
for i in 1 2 3 4 5 6 7 8 9; do
  hc add "$i" >/dev/null 2>&1 || true
done
hc use 1

# keybinds
Mod=Mod4
hc keybind "$Mod-Return" spawn alacritty
EOF
  if [[ -n "${launcher_cmd}" ]]; then
    printf "hc keybind \"\$Mod-d\" spawn %s\n" "${launcher_cmd}" >>"/home/${u}/.config/herbstluftwm/autostart"
  fi
  cat >> "/home/${u}/.config/herbstluftwm/autostart" <<'EOF'
hc keybind "$Mod-Shift-q" close
hc keybind "$Mod-Shift-e" quit

# directional focus/move
hc keybind "$Mod-h" focus left
hc keybind "$Mod-j" focus down
hc keybind "$Mod-k" focus up
hc keybind "$Mod-l" focus right
hc keybind "$Mod-Shift-h" shift left
hc keybind "$Mod-Shift-j" shift down
hc keybind "$Mod-Shift-k" shift up
hc keybind "$Mod-Shift-l" shift right

# startup helpers
if command -v pipewire >/dev/null 2>&1 && ! pgrep -x pipewire >/dev/null 2>&1; then
  pipewire &
fi
if command -v wireplumber >/dev/null 2>&1 && ! pgrep -x wireplumber >/dev/null 2>&1; then
  wireplumber &
fi
command -v blueman-applet >/dev/null 2>&1 && blueman-applet &
command -v picom >/dev/null 2>&1 && picom &
EOF
  printf "command -v feh >/dev/null 2>&1 && feh --bg-scale %q &\n" "${wallpaper_path}" >>"/home/${u}/.config/herbstluftwm/autostart"
  chmod 0755 "/home/${u}/.config/herbstluftwm/autostart"
  chown -R "${u}:${u}" "/home/${u}/.config/herbstluftwm"

  setup_xinitrc_for_x11 "$u" "herbstluftwm" "${wallpaper_path}"
}

setup_plasma_config() {
  local u="$1"
  info "Plasma: minimal setup. SDDM recommended."
  # Nothing heavy required; Plasma manages itself.
  # Provide a fallback startx entry too.
  setup_xinitrc_for_x11 "$u" "startplasma-x11" "${WALLPAPER_SYSTEM_PATH}"
}

setup_river_config() {
  local u="$1" launcher_cmd="${2:-wofi --show drun}" wallpaper_path="${3:-${WALLPAPER_SYSTEM_PATH}}"
  info "Generating river init for ${u}..."
  safe_mkdir "/home/${u}/.config/river"
  cat > "/home/${u}/.config/river/init" <<'EOF'
#!/usr/bin/env bash
set -e

# generated river init
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=river

# Start PipeWire / WirePlumber
pgrep -x pipewire >/dev/null || pipewire &
pgrep -x wireplumber >/dev/null || wireplumber &

# Wallpaper
EOF
  printf "command -v swaybg >/dev/null && swaybg -i %q -m fill &\n\n" "${wallpaper_path}" >>"/home/${u}/.config/river/init"
  cat >> "/home/${u}/.config/river/init" <<'EOF'

# Bluetooth tray (optional, on wlroots may need XWayland; still fine)
command -v blueman-applet >/dev/null && blueman-applet &
command -v Waybar >/dev/null && Waybar &

# Keybindings (super)
riverctl map normal Super Return spawn foot
EOF
  if [[ -n "${launcher_cmd}" ]]; then
    printf "riverctl map normal Super D spawn %s\n\n" "${launcher_cmd}" >>"/home/${u}/.config/river/init"
  fi
  cat >> "/home/${u}/.config/river/init" <<'EOF'
riverctl map normal Super Q close
riverctl map normal Super+Shift E exit

# Basic layout: rivertile if installed (optional)
if command -v rivertile >/dev/null 2>&1; then
  rivertile -view-padding 6 -outer-padding 6 &
fi

# Set repeat rate
riverctl set-repeat 50 300
EOF
  chmod 0755 "/home/${u}/.config/river/init"
  chown -R "${u}:${u}" "/home/${u}/.config/river"
}

setup_niri_config() {
  local u="$1" launcher_cmd="${2:-wofi --show drun}" wallpaper_path="${3:-${WALLPAPER_SYSTEM_PATH}}"
  info "Generating niri config for ${u}..."
  safe_mkdir "/home/${u}/.config/niri"
  cat > "/home/${u}/.config/niri/config.kdl" <<'EOF'
// generated niri config (minimal usable)
environment {
  XDG_SESSION_TYPE "wayland"
  XDG_CURRENT_DESKTOP "niri"
}

input {
  repeat-rate 50
  repeat-delay 300
}

spawn-at-startup "pipewire"
spawn-at-startup "wireplumber"
spawn-at-startup "blueman-applet"
spawn-at-startup "Waybar"
EOF
  printf "spawn-at-startup \"swaybg -i %s -m fill\"\n\n" "${wallpaper_path}" >>"/home/${u}/.config/niri/config.kdl"
  cat >> "/home/${u}/.config/niri/config.kdl" <<'EOF'

bindings {
  Mod4+Return spawn "foot"
EOF
  if [[ -n "${launcher_cmd}" ]]; then
    printf "  Mod4+D spawn \"%s\"\n" "${launcher_cmd}" >>"/home/${u}/.config/niri/config.kdl"
  fi
  cat >> "/home/${u}/.config/niri/config.kdl" <<'EOF'
  Mod4+Q close-window
  Mod4+Shift+E quit
}
EOF
  chown -R "${u}:${u}" "/home/${u}/.config/niri"
}

setup_hyprland_config() {
  local u="$1" launcher_cmd="${2:-wofi --show drun}" wallpaper_path="${3:-${WALLPAPER_SYSTEM_PATH}}"
  info "Generating Hyprland config for ${u} (experimental)..."
  safe_mkdir "/home/${u}/.config/hypr"
  cat >"/home/${u}/.config/hypr/hyprland.conf" <<'EOF'
# generated hyprland config (minimal usable)

monitor=,preferred,auto,auto

input {
  kb_layout = us
}

general {
  gaps_in = 5
  gaps_out = 10
  border_size = 2
}

decoration {
  rounding = 6
}

animations {
  enabled = 1
}

misc {
  disable_hyprland_logo = 1
}

bind = SUPER, Return, exec, foot
bind = SUPER, Q, killactive,
bind = SUPER SHIFT, E, exit,
EOF
  if [[ -n "${launcher_cmd}" ]]; then
    printf "bind = SUPER, D, exec, %s\n" "${launcher_cmd}" >>"/home/${u}/.config/hypr/hyprland.conf"
  fi
  printf "exec-once = pipewire\nexec-once = wireplumber\n" >>"/home/${u}/.config/hypr/hyprland.conf"
  printf "exec-once = swaybg -i %q -m fill\n" "${wallpaper_path}" >>"/home/${u}/.config/hypr/hyprland.conf"
  printf "exec-once = blueman-applet\n" >>"/home/${u}/.config/hypr/hyprland.conf"
  printf "exec-once = Waybar\n" >>"/home/${u}/.config/hypr/hyprland.conf"

  chown -R "${u}:${u}" "/home/${u}/.config/hypr"
}

setup_sway_config() {
  local u="$1" launcher_cmd="${2:-wofi --show drun}" wallpaper_path="${3:-${WALLPAPER_SYSTEM_PATH}}"
  info "Generating sway config for ${u}..."
  safe_mkdir "/home/${u}/.config/sway"
  cat > "/home/${u}/.config/sway/config" <<'EOF'
# generated sway config (minimal usable)
set $mod Mod4

bindsym $mod+Return exec foot
bindsym $mod+Shift+q kill
bindsym $mod+Shift+e exit

bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right

bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right

exec pipewire
exec wireplumber
exec Waybar
exec blueman-applet
EOF
  if [[ -n "${launcher_cmd}" ]]; then
    printf "bindsym \$mod+d exec %s\n" "${launcher_cmd}" >>"/home/${u}/.config/sway/config"
  fi
  printf "output * bg %q fill\n" "${wallpaper_path}" >>"/home/${u}/.config/sway/config"
  chown -R "${u}:${u}" "/home/${u}/.config/sway"
}

setup_wayland_session_desktop_file() {
  local name="$1" exec_cmd="$2"
  local path="/usr/share/wayland-sessions/${name}.desktop"
  safe_mkdir "$(dirname "$path")"
  cat > "$path" <<EOF
[Desktop Entry]
Name=${name}
Comment=Generated session
Exec=${exec_cmd}
Type=Application
EOF
}

setup_x11_session_desktop_file() {
  local name="$1" exec_cmd="$2"
  local path="/usr/share/xsessions/${name}.desktop"
  safe_mkdir "$(dirname "$path")"
  cat > "$path" <<EOF
[Desktop Entry]
Name=${name}
Comment=Generated session
Exec=${exec_cmd}
Type=Application
EOF
}

write_x11_wallpaper_wrapper() { # name, session_cmd, wallpaper_path
  local name="$1" session_cmd="$2" wallpaper_path="$3"
  local path="/usr/local/bin/void-auto-setup-${name}"
  safe_mkdir "$(dirname "${path}")"
  cat > "${path}" <<EOF
#!/usr/bin/env sh
set -eu
if command -v feh >/dev/null 2>&1; then
  feh --bg-scale "${wallpaper_path}" >/dev/null 2>&1 || true
fi
exec ${session_cmd}
EOF
  chmod 0755 "${path}"
  echo "${path}"
}

write_hyprland_launcher_wrapper() {
  local path="/usr/local/bin/void-auto-setup-start-hyprland"
  safe_mkdir "$(dirname "${path}")"
  cat > "${path}" <<'EOF'
#!/usr/bin/env sh
set -eu

find_hyprland_binary() {
  for candidate in /usr/bin/Hyprland /usr/bin/hyprland /bin/Hyprland /bin/hyprland; do
    if [ -x "${candidate}" ]; then
      printf "%s\n" "${candidate}"
      return 0
    fi
  done
  return 1
}

HYPRLAND_BIN="$(find_hyprland_binary || true)"
if [ -z "${HYPRLAND_BIN}" ]; then
  echo "Hyprland binary not found. Install package 'hyprland' first." >&2
  exit 127
fi

if [ -z "${XDG_SESSION_TYPE:-}" ]; then
  export XDG_SESSION_TYPE=wayland
fi
if [ -z "${XDG_CURRENT_DESKTOP:-}" ]; then
  export XDG_CURRENT_DESKTOP=Hyprland
fi
if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
  exec dbus-run-session -- "${HYPRLAND_BIN}"
fi

exec "${HYPRLAND_BIN}"
EOF
  chmod 0755 "${path}"

  # Convenience aliases for manual TTY startup.
  ln -sfn "${path}" /usr/local/bin/start-hyprland
  if [[ ! -x /usr/bin/hyprland ]]; then
    ln -sfn "${path}" /usr/local/bin/hyprland
  fi

  echo "${path}"
}

configure_session_files() {
  local de="$1" u="$2" lm="$3"
  local launcher_cmd="${4:-}" wallpaper_path="${5:-${WALLPAPER_SYSTEM_PATH}}"
  case "$de" in
    i3)
      setup_i3_config "$u" "${launcher_cmd:-dmenu_run}" "${wallpaper_path}"
      local i3_exec="i3"
      i3_exec="$(write_x11_wallpaper_wrapper "i3" "i3" "${wallpaper_path}")"
      setup_x11_session_desktop_file "i3" "${i3_exec}"
      # startx fallback
      setup_xinitrc_for_x11 "$u" "i3" "${wallpaper_path}"
      ;;
    plasma)
      setup_plasma_config "$u"
      local plasma_exec="startplasma-x11"
      plasma_exec="$(write_x11_wallpaper_wrapper "plasma-x11" "startplasma-x11" "${wallpaper_path}")"
      setup_x11_session_desktop_file "Plasma (X11)" "${plasma_exec}"
      # Wayland session typically provided by plasma; don't override.
      ;;
    dwm)
      setup_dwm_config "$u" "${wallpaper_path}"
      local dwm_exec="dwm"
      dwm_exec="$(write_x11_wallpaper_wrapper "dwm" "dwm" "${wallpaper_path}")"
      setup_x11_session_desktop_file "dwm" "${dwm_exec}"
      ;;
    awesome)
      setup_awesome_config "$u" "${wallpaper_path}"
      local awesome_exec="awesome"
      awesome_exec="$(write_x11_wallpaper_wrapper "awesome" "awesome" "${wallpaper_path}")"
      setup_x11_session_desktop_file "awesome" "${awesome_exec}"
      ;;
    herbstluftwm)
      setup_herbstluftwm_config "$u" "${launcher_cmd:-dmenu_run}" "${wallpaper_path}"
      local herbst_exec="herbstluftwm"
      herbst_exec="$(write_x11_wallpaper_wrapper "herbstluftwm" "herbstluftwm" "${wallpaper_path}")"
      setup_x11_session_desktop_file "herbstluftwm" "${herbst_exec}"
      ;;
    river)
      setup_river_config "$u" "${launcher_cmd:-wofi --show drun}" "${wallpaper_path}"
      setup_wayland_session_desktop_file "river" "river"
      ;;
    niri)
      setup_niri_config "$u" "${launcher_cmd:-wofi --show drun}" "${wallpaper_path}"
      # niri usually provides its own session; add one if missing
      setup_wayland_session_desktop_file "niri" "niri"
      ;;
    hyprland)
      setup_hyprland_config "$u" "${launcher_cmd:-wofi --show drun}" "${wallpaper_path}"
      local hypr_exec=""
      hypr_exec="$(write_hyprland_launcher_wrapper)"
      setup_wayland_session_desktop_file "Hyprland (experimental)" "${hypr_exec}"
      ;;
    sway)
      setup_sway_config "$u" "${launcher_cmd:-wofi --show drun}" "${wallpaper_path}"
      setup_wayland_session_desktop_file "sway" "sway"
      ;;
  esac

  # For greetd, user may need a configured command. We do a simple default.
  if [[ "$lm" == "greetd" ]]; then
    safe_mkdir /etc/greetd
    local cmd=""
    case "$de" in
      i3|dwm|plasma|awesome|herbstluftwm) cmd="startx" ;;
      river) cmd="river" ;;
      niri) cmd="niri" ;;
      hyprland) cmd="start-hyprland" ;;
      sway) cmd="sway" ;;
    esac
    cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --cmd ${cmd}"
user = "${u}"
EOF
    info "Configured greetd to start: ${cmd}"
  fi
}

# ---------------- browser ----------------
install_browser() {
  local b="$1"
  info "Installing browser: ${b}"
  if xbps-query -R "$b" >/dev/null 2>&1; then
    xbps_install "$b"
  else
    warn "Browser package not found: ${b}. Installing firefox instead."
    xbps_install firefox
  fi
}

# ---------------- final touches ----------------
final_notes() {
  cat <<'EOF'

============================================================
Done.

Notes:
- Services enabled (as applicable): dbus, elogind/seatd, bluetoothd, login-manager.
- PipeWire/WirePlumber are started via user autostart entries (no systemd user units on Void).
- If you chose "none" for login manager, use:
    startx
  from a TTY (after login) to start X11 sessions (i3/dwm/plasma/awesome/herbstluftwm).
- For Wayland sessions, use SDDM/LightDM/greetd, or run compositor from tty.

Log:
  /var/log/void-auto-setup.log
============================================================

EOF
}

maybe_reboot() {
  echo
  if yes_no "Reboot now to apply drivers/services fully?" "y"; then
    info "Rebooting..."
    reboot
  else
    info "Reboot skipped. You should reboot later."
  fi
}

# ---------------- main ----------------
main() {
  require_root
  detect_void
  show_splashscreen

  info "Void auto setup starting (version ${SCRIPT_VERSION})"
  xbps_install ca-certificates sudo || true
  xbps_sync

  local target_user seatstack de lm browser gpu want_flatpak="n" want_fastfetch="n"
  local want_fonts="y" session_kind launcher launcher_cmd want_wall_mgr="n" wall_mgr="none"
  local wallpaper_backend="none"
  local file_manager="none"
  target_user="$(choose_target_user)"
  seatstack="$(choose_session_stack)"
  de="$(choose_de)"
  lm="$(choose_login_manager)"
  seatstack="$(normalize_stack_for_login_manager "${seatstack}" "${lm}")"
  browser="$(choose_browser)"
  gpu="$(choose_gpu)"

  session_kind="$(session_kind_for_de "$de")"
  launcher="$(choose_launcher "${session_kind}")"
  launcher_cmd="$(launcher_cmd_for "${launcher}")"
  file_manager="$(choose_file_manager "${de}" "${session_kind}")"

  if yes_no "Install common fonts (DejaVu + Noto + Nerd Fonts if available)?" "y"; then
    want_fonts="y"
  else
    want_fonts="n"
  fi

  if yes_no "Install Flatpak + add Flathub?" "y"; then
    want_flatpak="y"
  fi
  if yes_no "Install fastfetch (for the vibes)?" "y"; then
    want_fastfetch="y"
  fi
  if yes_no "Install a wallpaper GUI manager?" "n"; then
    want_wall_mgr="y"
    wall_mgr="$(choose_wallpaper_manager "${session_kind}")"
    if [[ "${wall_mgr}" == "waypaper" ]]; then
      wallpaper_backend="$(choose_waypaper_backend "${session_kind}")"
    fi
  fi

  local steps=15
  if [[ "${want_flatpak}" == "y" ]]; then
    steps=$((steps + 1))
  fi
  if [[ "${want_fastfetch}" == "y" ]]; then
    steps=$((steps + 1))
  fi
  if [[ "${want_fonts}" == "y" ]]; then
    steps=$((steps + 1))
  fi
  if [[ "${launcher}" != "none" ]]; then
    steps=$((steps + 1))
  fi
  if [[ "${file_manager}" != "none" ]]; then
    steps=$((steps + 1))
  fi
  if [[ "${want_wall_mgr}" == "y" && "${wall_mgr}" != "none" ]]; then
    steps=$((steps + 1))
  fi
  if [[ "${wall_mgr}" == "waypaper" ]]; then
    steps=$((steps + 1))
  fi
  if [[ "${de}" == "hyprland" ]]; then
    steps=$((steps + 1))
  fi
  progress_init "${steps}"

  run_step "Enable Void repos" enable_void_repos
  run_step "Install core services (dbus + seat stack + polkit)" install_core_services "$seatstack"
  run_step "Install PipeWire + Bluetooth" install_pipewire_bluetooth
  run_step "Install development tools" install_dev_tools
  if [[ "${want_fonts}" == "y" ]]; then
    run_step "Install common fonts" install_fonts
  fi
  if [[ "${want_fastfetch}" == "y" ]]; then
    run_step "Install fastfetch" install_fastfetch
  fi
  run_step "Install GPU drivers (if detected)" install_gpu_drivers "$gpu"

  # DE/WM + session generation
  run_step "Install desktop/WM" install_de "$de"
  if [[ "${de}" == "hyprland" ]]; then
    run_step "Install Hyprland (experimental workaround)" install_hyprland_experimental
  fi
  run_step "Install login manager" install_login_manager "$lm"
  if [[ "${launcher}" != "none" ]]; then
    run_step "Install app launcher" install_launcher "${launcher}"
  fi
  if [[ "${file_manager}" != "none" ]]; then
    run_step "Install file manager" install_file_manager "${file_manager}"
  fi
  if [[ "${want_wall_mgr}" == "y" && "${wall_mgr}" != "none" ]]; then
    run_step "Install wallpaper manager" install_wallpaper_manager "${wall_mgr}" "${session_kind}" "${wallpaper_backend}"
  fi
  run_step "Install sample wallpaper" install_sample_wallpaper

  run_step "Ensure user groups" ensure_groups_for_seat_stack "$seatstack" "$target_user"
  run_step "Set up user autostart bits" setup_common_user_bits "$target_user"
  if [[ "${wall_mgr}" == "waypaper" ]]; then
    run_step "Configure Waypaper restore autostart" setup_waypaper_restore_autostart "$target_user"
  fi
  run_step "Generate session/config files" configure_session_files "$de" "$target_user" "$lm" "${launcher_cmd}" "${WALLPAPER_SYSTEM_PATH}"

  run_step "Install browser" install_browser "$browser"

  if [[ "${want_flatpak}" == "y" ]]; then
    run_step "Install Flatpak + Flathub" install_flatpak
  fi

  run_step "Install gaming/multilib extras" install_gaming_multilib

  run_step "Print final notes" final_notes
  maybe_reboot
}

main "$@"
