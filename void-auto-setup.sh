#!/usr/bin/env bash
#
# void-postinstall.sh — Interactive post-installation setup for Void Linux
#
# Run as root on a freshly installed Void Linux base system.
# Covers: seat/session management, X11/Wayland desktop environments,
# graphics drivers (Mesa/Vulkan/VA-API), app launcher (rofi/wofi),
# Bluetooth, and PipeWire audio.
#

set -euo pipefail

# ----------------------------------------------------------------------------
# Splash screen
# ----------------------------------------------------------------------------
_splashscreen_fallback() {
  cat <<'EOF'
██╗   ██╗  ██████╗  ██╗██████╗
██║   ██║ ██╔═══██╗ ██║██╔══██╗
██║   ██║ ██║   ██║ ██║██║  ██║
╚██╗ ██╔╝ ██║   ██║ ██║██║  ██║
 ╚████╔╝  ╚██████╔╝ ██║██████╔╝
  ╚═══╝    ╚═════╝  ╚═╝╚═════╝

 ██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗     ███████╗██████╗
 ██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║     ██╔════╝██╔══██╗
 ██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║     █████╗  ██████╔╝
 ██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║     ██╔══╝  ██╔══██╗
 ██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗███████╗██║  ██║
 ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝  ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝
EOF
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
msg()  { printf '\n\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[1;34m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*"; }

install_pkgs() {
  msg "Installing: $*"
  xbps-install -y "$@"
}

# Enable a runit service by symlinking /etc/sv/<name> -> /var/service/
enable_service() {
  local svc="$1"
  if [ ! -d "/etc/sv/${svc}" ]; then
    warn "Service directory /etc/sv/${svc} does not exist; skipping enable."
    return 0
  fi
  if [ -e "/var/service/${svc}" ]; then
    info "Service '${svc}' is already enabled."
  else
    ln -s "/etc/sv/${svc}" /var/service/
    info "Service '${svc}' enabled (symlinked to /var/service/)."
  fi
}

# Check whether a package exists in the configured repos.
pkg_available() { xbps-query -R "$1" >/dev/null 2>&1; }

# Install only the packages that actually exist in the repos; warn about the rest.
install_avail() {
  local found=() p
  for p in "$@"; do
    if pkg_available "$p"; then
      found+=("$p")
    else
      warn "Package not found in repos (skipping): $p"
    fi
  done
  if ((${#found[@]})); then
    install_pkgs "${found[@]}"
  fi
}

# Install the first package from a list of candidate names that exists.
install_first_avail() {
  local label="$1"; shift
  local p
  for p in "$@"; do
    if pkg_available "$p"; then
      install_pkgs "$p"
      return 0
    fi
  done
  warn "No package found for ${label} (tried: $*)."
}

# Add the unofficial hyprland-void binary repo (github.com/sofijacom/hyprland-void).
# Void does not package Hyprland officially; this repo provides signed binary
# packages for x86_64/aarch64 on both glibc and musl. Returns 1 if the current
# arch/libc combination is not supported.
setup_hyprland_repo() {
  local arch libc suffix conf="/etc/xbps.d/hyprland-void.conf"
  arch="$(uname -m)"
  if ldd --version 2>&1 | grep -qi musl; then libc="musl"; else libc="glibc"; fi
  case "${arch}-${libc}" in
    x86_64-glibc|x86_64-musl|aarch64-glibc|aarch64-musl)
      suffix="${arch}-${libc}"
      ;;
    *)
      warn "hyprland-void provides no packages for ${arch}-${libc}."
      return 1
      ;;
  esac

  if [ -f "$conf" ] && grep -q "sofijacom/hyprland-void" "$conf" 2>/dev/null; then
    info "hyprland-void repository already configured (${conf})."
  else
    msg "Adding unofficial hyprland-void repository (${suffix})"
    mkdir -p /etc/xbps.d
    echo "repository=https://raw.githubusercontent.com/sofijacom/hyprland-void/repository-${suffix}" > "$conf"
  fi

  msg "Syncing repositories — accept the hyprland-void fingerprint when prompted"
  xbps-install -S
}

# Enable the nonfree repository (proprietary drivers, firmware, Steam).
enable_nonfree_repo() {
  if xbps-query void-repo-nonfree >/dev/null 2>&1; then
    info "nonfree repository already enabled."
    return 0
  fi
  msg "Enabling the nonfree repository"
  install_avail void-repo-nonfree
  xbps-install -Sy
}

# Enable the 32-bit (multilib) repositories. Returns 1 when the platform
# cannot support them (multilib is x86_64 + glibc only).
MULTILIB_READY=0
enable_multilib_repos() {
  if [ "$MULTILIB_READY" -eq 1 ]; then
    return 0
  fi
  if [ "$(uname -m)" != "x86_64" ]; then
    warn "32-bit libraries require x86_64; skipping multilib."
    return 1
  fi
  if ldd --version 2>&1 | grep -qi musl; then
    warn "multilib is not available on musl systems; skipping 32-bit libraries."
    return 1
  fi
  msg "Enabling the multilib repositories"
  install_avail void-repo-multilib void-repo-multilib-nonfree
  xbps-install -Sy
  MULTILIB_READY=1
}

# Yes/no prompt. Returns 0 for yes, 1 for no.
ask_yn() {
  local prompt="$1" def="${2:-n}" show a
  if [ "$def" = "y" ]; then show="Y/n"; else show="y/N"; fi
  while true; do
    read -rp "${prompt} [${show}]: " a
    a="${a:-$def}"
    case "${a,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

# Multi-select prompt. Fills the CHOICES array with the selected labels.
# Input: numbers separated by spaces (e.g. "1 3 4"), 'a' for all, Enter for none.
choose_multi() {
  local prompt="$1"; shift
  local options=("$@")
  local i sel t picked valid
  CHOICES=()
  echo
  echo "${prompt}"
  for i in "${!options[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${options[$i]}"
  done
  echo "  (numbers separated by spaces, 'a' for all, Enter for none)"
  while true; do
    read -rp "Selection: " sel
    if [ -z "$sel" ]; then
      return 0
    fi
    if [ "$sel" = "a" ] || [ "$sel" = "A" ]; then
      CHOICES=("${options[@]}")
      return 0
    fi
    valid=1
    picked=()
    for t in $sel; do
      if [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -ge 1 ] && [ "$t" -le "${#options[@]}" ]; then
        picked+=("${options[$((t - 1))]}")
      else
        valid=0
        break
      fi
    done
    if [ "$valid" -eq 1 ]; then
      CHOICES=("${picked[@]}")
      return 0
    fi
    warn "Invalid selection, try again."
  done
}

# Prompt the user to pick one item from a list. Sets REPLY_CHOICE.
choose() {
  local prompt="$1"; shift
  local options=("$@")
  local i sel
  echo
  echo "${prompt}"
  for i in "${!options[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${options[$i]}"
  done
  while true; do
    read -rp "Enter choice [1-${#options[@]}]: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#options[@]}" ]; then
      REPLY_CHOICE="${options[$((sel - 1))]}"
      return 0
    fi
    warn "Invalid selection, try again."
  done
}

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
_splashscreen_fallback

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root." >&2
  exit 1
fi

if ! command -v xbps-install >/dev/null 2>&1; then
  echo "ERROR: xbps-install not found. Is this a Void Linux system?" >&2
  exit 1
fi

msg "Synchronizing repositories and updating the system"
xbps-install -Syu xbps
xbps-install -Syu

# D-Bus is required by elogind, bluetoothd, PipeWire and every desktop below.
install_pkgs dbus
enable_service dbus

# ----------------------------------------------------------------------------
# 1. Session and seat management (elogind vs seatd)
# ----------------------------------------------------------------------------
msg "Session and seat management"
choose "Which seat/session manager do you want to use?" \
  "elogind  (recommended for GNOME, KDE Plasma, XFCE and most desktops)" \
  "seatd    (lightweight, common for Sway/wlroots setups)"

case "$REPLY_CHOICE" in
  elogind*)
    SEAT_MANAGER="elogind"
    install_pkgs elogind
    # elogind is normally D-Bus activated on Void; enable a runit service
    # only if the package ships one.
    if [ -d /etc/sv/elogind ]; then
      enable_service elogind
    else
      info "elogind is started on demand via D-Bus activation (no runit service needed)."
    fi
    ;;
  seatd*)
    SEAT_MANAGER="seatd"
    install_pkgs seatd
    enable_service seatd
    warn "Remember to add your user to the '_seatd' group:  usermod -aG _seatd <username>"
    ;;
esac
info "Seat manager: ${SEAT_MANAGER}"

# ----------------------------------------------------------------------------
# 2. Display server + desktop environment
# ----------------------------------------------------------------------------
msg "Display server selection"
choose "Do you want an X11 or a Wayland environment?" "X11" "Wayland"
DISPLAY_SERVER="$REPLY_CHOICE"

DM_SERVICE=""

if [ "$DISPLAY_SERVER" = "X11" ]; then
  msg "Installing Xorg base packages"
  install_pkgs xorg-minimal xorg-fonts xterm

  choose "Choose an X11 desktop environment / window manager:" \
    "GNOME" "KDE Plasma" "XFCE" "MATE" "Cinnamon" "LXQt" "i3"

  case "$REPLY_CHOICE" in
    "GNOME")
      install_pkgs gnome gnome-tweaks gdm
      DM_SERVICE="gdm"
      ;;
    "KDE Plasma")
      install_pkgs kde-plasma kde-baseapps sddm
      DM_SERVICE="sddm"
      ;;
    "XFCE")
      install_pkgs xfce4 lightdm lightdm-gtk3-greeter
      DM_SERVICE="lightdm"
      ;;
    "MATE")
      install_pkgs mate mate-extra lightdm lightdm-gtk3-greeter
      DM_SERVICE="lightdm"
      ;;
    "Cinnamon")
      install_pkgs cinnamon lightdm lightdm-gtk3-greeter
      DM_SERVICE="lightdm"
      ;;
    "LXQt")
      install_pkgs lxqt sddm
      DM_SERVICE="sddm"
      ;;
    "i3")
      install_pkgs i3 i3status i3lock dmenu xinit
      info "Start i3 with 'startx' after adding 'exec i3' to ~/.xinitrc."
      ;;
  esac
else
  msg "Installing Wayland base packages"
  install_pkgs wayland wayland-protocols xdg-desktop-portal xdg-desktop-portal-wlr

  choose "Choose a Wayland desktop environment / compositor:" \
    "GNOME (Wayland)" "KDE Plasma (Wayland)" "Sway" "Wayfire" "River" \
    "Hyprland (unofficial hyprland-void repo)"

  case "$REPLY_CHOICE" in
    "GNOME (Wayland)")
      install_pkgs gnome gnome-tweaks gdm
      DM_SERVICE="gdm"
      ;;
    "KDE Plasma (Wayland)")
      install_pkgs kde-plasma kde-baseapps sddm
      DM_SERVICE="sddm"
      ;;
    "Sway")
      install_pkgs sway swaybg swaylock swayidle foot
      info "Start Sway from a TTY by running 'sway'."
      ;;
    "Wayfire")
      install_pkgs wayfire foot
      info "Start Wayfire from a TTY by running 'wayfire'."
      ;;
    "River")
      install_pkgs river foot
      info "Start River from a TTY by running 'river'."
      ;;
    "Hyprland (unofficial hyprland-void repo)")
      warn "Hyprland is NOT in the official Void repositories."
      warn "This uses the unofficial binary repo github.com/sofijacom/hyprland-void"
      warn "(signed packages, built via GitHub Actions from void-packages templates)."
      if ask_yn "Add the hyprland-void repository and install Hyprland?" "y"; then
        if setup_hyprland_repo; then
          msg "Installing Hyprland and its supporting stack"
          install_avail hyprland xdg-desktop-portal-hyprland hyprpolkitagent \
            hyprpaper hyprlock hypridle
          install_avail xorg-server-xwayland xdg-desktop-portal-gtk \
            kitty grim slurp wl-clipboard
          install_first_avail "Waybar" Waybar waybar

          # Starter config: Hyprland's packaged default lacks Void-specific
          # autostarts (PipeWire has no service on Void; polkit agent needed).
          mkdir -p /etc/skel/.config/hypr
          cat > /etc/skel/.config/hypr/hyprland.conf <<'HYPR'
# Generated starter config — see https://wiki.hyprland.org for full options
monitor = , preferred, auto, auto

input {
    kb_layout = us
}

general {
    gaps_in = 4
    gaps_out = 8
    border_size = 2
}

misc {
    disable_hyprland_logo = true
}

# Void has no systemd user units: start the session services here.
exec-once = pipewire
exec-once = wireplumber
exec-once = hyprpolkitagent
exec-once = waybar
exec-once = hyprpaper

bind = SUPER, Return, exec, kitty
bind = SUPER, D, exec, wofi --show drun
bind = SUPER, Q, killactive,
bind = SUPER SHIFT, E, exit,
HYPR
          info "Starter config written to /etc/skel/.config/hypr/hyprland.conf"
          info "(copied for new users; existing users can copy it to ~/.config/hypr/)."
          info "Start Hyprland from a TTY by running 'Hyprland' (capital H)."
        else
          warn "Unsupported platform for hyprland-void — Hyprland was not installed."
        fi
      else
        warn "Hyprland installation declined — no desktop was installed."
      fi
      ;;
  esac
fi

DESKTOP_CHOICE="$REPLY_CHOICE"

if [ -n "$DM_SERVICE" ]; then
  msg "Enabling display manager: ${DM_SERVICE}"
  enable_service "$DM_SERVICE"
fi

# ----------------------------------------------------------------------------
# 3. Graphics drivers (Mesa / Vulkan / VA-API)
# ----------------------------------------------------------------------------
msg "Graphics drivers"

# lspci lives in pciutils, which a minimal base install may not have.
if ! command -v lspci >/dev/null 2>&1; then
  install_avail pciutils
fi

# Detect the GPU vendors present on this machine (best effort, used as a hint).
DETECTED_GPUS=()
detect_gpus() {
  local line v
  command -v lspci >/dev/null 2>&1 || return 0
  while IFS= read -r line; do
    v=""
    case "${line,,}" in
      *nvidia*)                          v="NVIDIA" ;;
      *intel*)                           v="Intel" ;;
      *amd*|*ati*|*radeon*)              v="AMD" ;;
      *virtio*|*vmware*|*virtualbox*|*innotek*|*qxl*|*"red hat"*|*bochs*|*cirrus*)
                                         v="Virtual" ;;
    esac
    [ -n "$v" ] || continue
    # Avoid listing the same vendor twice (hybrid laptops report two devices).
    case " ${DETECTED_GPUS[*]-} " in *" $v "*) continue ;; esac
    DETECTED_GPUS+=("$v")
  done < <(lspci 2>/dev/null | grep -Ei 'vga compatible controller|3d controller|display controller')
}
detect_gpus

if ((${#DETECTED_GPUS[@]})); then
  info "Detected GPU vendor(s): ${DETECTED_GPUS[*]}"
else
  warn "Could not detect a GPU automatically — pick your driver(s) manually."
fi

# Mesa, the Vulkan loader/ICD infrastructure and the video-acceleration
# front-ends are needed by every GPU, including the proprietary NVIDIA stack.
msg "Installing the common graphics stack (Mesa, Vulkan loader, VA-API/VDPAU)"
install_avail mesa mesa-dri vulkan-loader Vulkan-Tools mesa-vulkan-lvp \
  mesa-vaapi mesa-vdpau libva libva-utils vdpauinfo libvdpau
if [ "$DISPLAY_SERVER" = "X11" ]; then
  install_avail xf86-input-libinput
else
  install_avail libinput
fi

choose_multi "Which GPU driver(s) do you want to install?" \
  "Intel (mesa-vulkan-intel + VA-API)" \
  "AMD / ATI (mesa-vulkan-radeon + VA-API)" \
  "NVIDIA — proprietary (nonfree repo, DKMS module)" \
  "NVIDIA — open source (nouveau)" \
  "Virtual machine guest (QEMU/virtio, VMware, VirtualBox)"

GPU_VENDORS=()
for c in "${CHOICES[@]}"; do
  case "$c" in
    "Intel"*)
      GPU_VENDORS+=("intel")
      install_avail mesa-vulkan-intel intel-video-accel
      # Gen8+ uses intel-media-driver, older chips use libva-intel-driver.
      install_avail intel-media-driver libva-intel-driver
      install_avail linux-firmware-intel
      if [ "$DISPLAY_SERVER" = "X11" ]; then
        install_avail xf86-video-intel
        info "The modesetting driver is preferred over xf86-video-intel on Gen4+;"
        info "remove xf86-video-intel if you hit tearing or crashes."
      fi
      ;;
    "AMD"*)
      GPU_VENDORS+=("amd")
      install_avail mesa-vulkan-radeon linux-firmware-amd
      if [ "$DISPLAY_SERVER" = "X11" ]; then
        # Pre-GCN cards (radeon kernel driver) still use the ati DDX.
        install_avail xf86-video-amdgpu xf86-video-ati
      fi
      ;;
    "NVIDIA — proprietary"*)
      GPU_VENDORS+=("nvidia")
      if enable_nonfree_repo; then
        # The DKMS module needs headers for the running kernel.
        install_avail linux-headers dkms
        install_avail nvidia nvidia-firmware
        install_avail nvidia-vaapi-driver
        warn "The NVIDIA module is built with DKMS — this can take a few minutes."
        warn "Reboot before starting a graphical session; nouveau is blacklisted"
        warn "by the nvidia package, so the change only applies after reboot."
        if [ "$DISPLAY_SERVER" != "X11" ]; then
          warn "For Wayland, make sure nvidia_drm.modeset=1 is set (the Void package"
          warn "ships this in /etc/modprobe.d — verify after reboot with:"
          warn "  cat /sys/module/nvidia_drm/parameters/modeset)"
        fi
      fi
      ;;
    "NVIDIA — open source"*)
      GPU_VENDORS+=("nouveau")
      install_avail mesa-nouveau-dri mesa-vulkan-nouveau
      if [ "$DISPLAY_SERVER" = "X11" ]; then
        install_avail xf86-video-nouveau
      fi
      warn "nouveau has no reclocking on most modern cards — expect low performance."
      ;;
    "Virtual machine guest"*)
      GPU_VENDORS+=("virtual")
      # Guests fall back to the lavapipe software renderer already installed above.
      if [ "$DISPLAY_SERVER" = "X11" ]; then
        install_avail xf86-video-vmware xf86-video-qxl
      fi
      info "For VirtualBox also install 'virtualbox-ose-guest' and enable vboxservice."
      ;;
  esac
done

if ((${#GPU_VENDORS[@]})); then
  SELECTED_GPU_SUMMARY="${CHOICES[*]}"
else
  SELECTED_GPU_SUMMARY="none (generic Mesa only)"
  warn "No vendor driver selected — only the generic Mesa stack was installed."
fi

# 32-bit userspace: required by Steam, Wine and most Proton titles.
if ask_yn "Install 32-bit graphics libraries too? (needed for Steam/Wine)" "n"; then
  if enable_multilib_repos; then
    install_avail mesa-dri-32bit vulkan-loader-32bit libgcc-32bit libstdc++-32bit
    for v in "${GPU_VENDORS[@]}"; do
      case "$v" in
        intel)   install_avail mesa-vulkan-intel-32bit libva-intel-driver-32bit ;;
        amd)     install_avail mesa-vulkan-radeon-32bit ;;
        nvidia)  install_avail nvidia-libs-32bit ;;
        nouveau) install_avail mesa-nouveau-dri-32bit ;;
      esac
    done
    SELECTED_GPU_SUMMARY="${SELECTED_GPU_SUMMARY} + 32-bit libs"
  fi
fi

info "Verify Vulkan after reboot with 'vulkaninfo --summary' and VA-API with 'vainfo'."

# ----------------------------------------------------------------------------
# 4. Application launcher (rofi for X11, wofi for Wayland)
# ----------------------------------------------------------------------------
if [ "$DISPLAY_SERVER" = "X11" ]; then
  msg "Installing and configuring rofi (X11 application launcher)"
  install_pkgs rofi
  mkdir -p /etc/skel/.config/rofi
  cat > /etc/skel/.config/rofi/config.rasi <<'ROFI'
configuration {
    modi: "drun,run,window";
    show-icons: true;
    icon-theme: "Adwaita";
    display-drun: "Apps";
    display-run: "Run";
    display-window: "Windows";
}
@theme "gruvbox-dark"
ROFI
  info "Default rofi config written to /etc/skel/.config/rofi/config.rasi"
  info "(copied into the home directory of every user created from now on;"
  info " existing users can copy it manually). Launch with: rofi -show drun"
else
  msg "Installing and configuring wofi (Wayland application launcher)"
  install_pkgs wofi
  mkdir -p /etc/skel/.config/wofi
  cat > /etc/skel/.config/wofi/config <<'WOFI'
show=drun
allow_images=true
insensitive=true
prompt=Search...
width=40%
height=45%
WOFI
  cat > /etc/skel/.config/wofi/style.css <<'WOFICSS'
window {
  background-color: #282828;
  border: 2px solid #504945;
  border-radius: 8px;
  font-family: monospace;
}
#input {
  margin: 8px;
  border-radius: 4px;
  background-color: #3c3836;
  color: #ebdbb2;
}
#entry:selected {
  background-color: #504945;
}
#text {
  color: #ebdbb2;
}
WOFICSS
  info "Default wofi config written to /etc/skel/.config/wofi/"
  info "(copied into the home directory of every user created from now on;"
  info " existing users can copy it manually). Launch with: wofi"
fi

# ----------------------------------------------------------------------------
# 5. Application selection (tuxmate-style)
# ----------------------------------------------------------------------------
msg "Application selection"
info "Pick the applications you want. Every category can be skipped."
SELECTED_SUMMARY=()

# --- Web browsers (multi-select) ---
choose_multi "Which web browsers do you want to install?" \
  "Firefox" "Chromium" "Epiphany (GNOME Web)" "qutebrowser" "Falkon"
for c in "${CHOICES[@]}"; do
  case "$c" in
    "Firefox")               install_avail firefox ;;
    "Chromium")              install_avail chromium ;;
    "Epiphany (GNOME Web)")  install_avail epiphany ;;
    "qutebrowser")           install_avail qutebrowser ;;
    "Falkon")                install_avail falkon ;;
  esac
done
if ((${#CHOICES[@]})); then SELECTED_SUMMARY+=("Browsers: ${CHOICES[*]}"); fi

# --- File managers (multi-select) ---
choose_multi "Which file managers do you want to install?" \
  "Thunar (GTK)" "PCManFM (GTK, light)" "Nemo (GTK)" "Dolphin (Qt/KDE)" "ranger (terminal)"
for c in "${CHOICES[@]}"; do
  case "$c" in
    "Thunar (GTK)")          install_avail thunar ;;
    "PCManFM (GTK, light)")  install_avail pcmanfm ;;
    "Nemo (GTK)")            install_avail nemo ;;
    "Dolphin (Qt/KDE)")      install_avail dolphin ;;
    "ranger (terminal)")     install_avail ranger ;;
  esac
done
if ((${#CHOICES[@]})); then SELECTED_SUMMARY+=("File managers: ${CHOICES[*]}"); fi

# --- Programming tools (multi-select) ---
choose_multi "Which programming tools do you want to install?" \
  "base-devel + git (gcc, make, headers)" \
  "Python 3 + pip" \
  "Node.js" \
  "Go" \
  "Rust (rustc + cargo)" \
  "Clang/LLVM" \
  "Java (OpenJDK)" \
  "CMake + Ninja + pkg-config" \
  "Debugging (gdb, strace)" \
  "Docker" \
  "Podman"
for c in "${CHOICES[@]}"; do
  case "$c" in
    "base-devel + git (gcc, make, headers)") install_avail base-devel git ;;
    "Python 3 + pip")                        install_avail python3 python3-pip ;;
    "Node.js")                               install_avail nodejs ;;
    "Go")                                    install_avail go ;;
    "Rust (rustc + cargo)")                  install_avail rust cargo ;;
    "Clang/LLVM")                            install_avail clang ;;
    "Java (OpenJDK)")                        install_first_avail "OpenJDK" openjdk21 openjdk17 openjdk11 ;;
    "CMake + Ninja + pkg-config")            install_avail cmake ninja pkg-config ;;
    "Debugging (gdb, strace)")               install_avail gdb strace ;;
    "Docker")
      install_avail docker
      enable_service containerd
      enable_service docker
      warn "Add your user to the 'docker' group for rootless CLI access:  usermod -aG docker <username>"
      ;;
    "Podman")                                install_avail podman ;;
  esac
done
if ((${#CHOICES[@]})); then SELECTED_SUMMARY+=("Dev tools: ${CHOICES[*]}"); fi

# --- Code editors (multi-select) ---
choose_multi "Which code editors do you want to install?" \
  "Neovim" "Vim" "Emacs" "VS Code" "Geany" "micro" "Kate"
for c in "${CHOICES[@]}"; do
  case "$c" in
    "Neovim")  install_avail neovim ;;
    "Vim")     install_avail vim ;;
    "Emacs")   install_first_avail "Emacs" emacs-gtk3 emacs ;;
    "VS Code") install_avail vscode ;;
    "Geany")   install_avail geany ;;
    "micro")   install_avail micro ;;
    "Kate")    install_avail kate ;;
  esac
done
if ((${#CHOICES[@]})); then SELECTED_SUMMARY+=("Editors: ${CHOICES[*]}"); fi

# --- VPN & networking (multi-select) ---
choose_multi "Which VPN / networking packages do you want?" \
  "NetworkManager (+ applet)" "WireGuard" "OpenVPN" "OpenSSH server (sshd)" "Tailscale"
for c in "${CHOICES[@]}"; do
  case "$c" in
    "NetworkManager (+ applet)")
      install_avail NetworkManager network-manager-applet
      # NetworkManager conflicts with dhcpcd/wpa_supplicant managing interfaces.
      if [ -e /var/service/dhcpcd ]; then
        rm -f /var/service/dhcpcd
        info "Disabled dhcpcd service (NetworkManager takes over DHCP)."
      fi
      if [ -e /var/service/wpa_supplicant ]; then
        rm -f /var/service/wpa_supplicant
        info "Disabled standalone wpa_supplicant service (managed by NetworkManager)."
      fi
      enable_service NetworkManager
      ;;
    "WireGuard")               install_avail wireguard-tools ;;
    "OpenVPN")                 install_avail openvpn ;;
    "OpenSSH server (sshd)")
      install_avail openssh
      enable_service sshd
      ;;
    "Tailscale")
      install_avail tailscale
      enable_service tailscaled
      info "Run 'tailscale up' after reboot to authenticate."
      ;;
  esac
done
if ((${#CHOICES[@]})); then SELECTED_SUMMARY+=("Networking: ${CHOICES[*]}"); fi

# --- Terminal emulator (single choice) ---
choose "Which terminal emulator do you want as your main terminal?" \
  "Alacritty (GPU-accelerated, X11+Wayland)" \
  "Kitty (GPU-accelerated, X11+Wayland)" \
  "Foot (lightweight, Wayland only)" \
  "XTerm (classic, X11)" \
  "Skip (keep the desktop environment's default)"
case "$REPLY_CHOICE" in
  Alacritty*) install_avail alacritty; SELECTED_SUMMARY+=("Terminal: Alacritty") ;;
  Kitty*)     install_avail kitty;     SELECTED_SUMMARY+=("Terminal: Kitty") ;;
  Foot*)      install_avail foot;      SELECTED_SUMMARY+=("Terminal: Foot") ;;
  XTerm*)     install_avail xterm;     SELECTED_SUMMARY+=("Terminal: XTerm") ;;
  Skip*)      info "Keeping the desktop environment's default terminal." ;;
esac

# --- Media players (multi-select) ---
choose_multi "Which media players do you want to install?" \
  "mpv" "VLC" "Celluloid (mpv GUI)" "Audacious (music)"
for c in "${CHOICES[@]}"; do
  case "$c" in
    "mpv")                 install_avail mpv ;;
    "VLC")                 install_avail vlc ;;
    "Celluloid (mpv GUI)") install_avail celluloid ;;
    "Audacious (music)")   install_avail audacious ;;
  esac
done
if ((${#CHOICES[@]})); then SELECTED_SUMMARY+=("Media: ${CHOICES[*]}"); fi

# --- Password manager (single choice) ---
choose "Do you want a password manager?" \
  "KeePassXC (graphical)" \
  "pass (command-line, GPG-based)" \
  "Skip"
case "$REPLY_CHOICE" in
  KeePassXC*) install_avail keepassxc; SELECTED_SUMMARY+=("Password manager: KeePassXC") ;;
  pass*)      install_avail pass gnupg; SELECTED_SUMMARY+=("Password manager: pass") ;;
  Skip)       info "No password manager selected." ;;
esac

# --- Extras (yes/no) ---
msg "Extras"
if ask_yn "Install Steam? (enables the nonfree + multilib repos and 32-bit libraries)" "n"; then
  if ldd --version 2>&1 | grep -qi musl; then
    warn "Steam is not available on musl systems; skipping."
  elif enable_nonfree_repo && enable_multilib_repos; then
    install_avail steam mesa-dri-32bit vulkan-loader-32bit libgcc-32bit libstdc++-32bit
    for v in "${GPU_VENDORS[@]}"; do
      case "$v" in
        intel)   install_avail mesa-vulkan-intel-32bit ;;
        amd)     install_avail mesa-vulkan-radeon-32bit ;;
        nvidia)  install_avail nvidia-libs-32bit ;;
        nouveau) install_avail mesa-nouveau-dri-32bit ;;
      esac
    done
    SELECTED_SUMMARY+=("Gaming: Steam + 32-bit libs")
  fi
fi
if ask_yn "Install fastfetch?" "y"; then
  install_avail fastfetch
  SELECTED_SUMMARY+=("Extras: fastfetch")
fi
if ask_yn "Install LibreOffice?" "n"; then
  install_avail libreoffice
  SELECTED_SUMMARY+=("Extras: LibreOffice")
fi
if ask_yn "Install Thunderbird (email client)?" "n"; then
  install_avail thunderbird
  SELECTED_SUMMARY+=("Extras: Thunderbird")
fi

# ----------------------------------------------------------------------------
# 6. Bluetooth
# ----------------------------------------------------------------------------
msg "Bluetooth setup"
install_pkgs bluez libspa-bluetooth
enable_service bluetoothd
warn "Add your user to the 'bluetooth' group for device access:  usermod -aG bluetooth <username>"

# ----------------------------------------------------------------------------
# 7. PipeWire (per the official Void Linux documentation, system-wide config)
# ----------------------------------------------------------------------------
msg "PipeWire sound setup"

# Remove PulseAudio if present — it conflicts with pipewire-pulse.
if xbps-query pulseaudio >/dev/null 2>&1; then
  msg "Removing conflicting pulseaudio package"
  xbps-remove -Ry pulseaudio
else
  info "pulseaudio is not installed — nothing to remove."
fi

install_pkgs pipewire wireplumber

msg "Creating system-wide PipeWire configuration"
mkdir -p /etc/pipewire/pipewire.conf.d

# WirePlumber session manager
if [ ! -e /etc/pipewire/pipewire.conf.d/10-wireplumber.conf ]; then
  ln -s /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
  info "Enabled WirePlumber session manager (10-wireplumber.conf)."
else
  info "WirePlumber config already in place."
fi

# PulseAudio compatibility interface
if [ ! -e /etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf ]; then
  ln -s /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/
  info "Enabled PipeWire PulseAudio interface (20-pipewire-pulse.conf)."
else
  info "PipeWire-Pulse config already in place."
fi

warn "PipeWire requires an active D-Bus USER session bus."
warn "Launch 'pipewire' via your desktop environment or window manager's"
warn "autostart mechanism (e.g. XDG autostart, or 'exec pipewire' in your"
warn "sway/i3 config) — it is NOT run as a system-wide runit service."

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
msg "Post-installation setup complete!"
echo
info "Summary:"
info "  Seat manager:    ${SEAT_MANAGER}"
info "  Display server:  ${DISPLAY_SERVER}"
info "  Desktop:         ${DESKTOP_CHOICE}"
info "  Graphics:        ${SELECTED_GPU_SUMMARY}"
info "  Audio:           PipeWire + WirePlumber (system-wide config)"
info "  Bluetooth:       bluez + libspa-bluetooth (bluetoothd enabled)"
if ((${#SELECTED_SUMMARY[@]})); then
  for line in "${SELECTED_SUMMARY[@]}"; do
    info "  ${line}"
  done
fi
echo
info "Reboot to start your new desktop environment:  reboot"
