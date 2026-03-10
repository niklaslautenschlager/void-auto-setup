# Void Auto Setup

Post-install setup script for a fresh **Void Linux (runit)** install.

## Quick Start

Clone the repo, enter the directory, make the installer executable, and run it as root:

```bash
git clone https://github.com/niklaslautenschlager/void-auto-setup.git
cd void-auto-setup
chmod +x void-auto-setup.sh
sudo ./void-auto-setup.sh
```

This script:

- Runs a full first-boot system update (`xbps-install -Suy`) and installs `sudo`, `git`, `curl`, and `xtools`.
- Enables Void repos (nonfree, multilib where available).
- Installs core services: `dbus` plus either `elogind` or `seatd`, and `polkit`.
- Sets up **PipeWire + WirePlumber** audio, including `pipewire-pulse`, `pulseaudio-utils`, `pavucontrol`, PipeWire example symlinks, and XDG autostart entries.
- Installs Bluetooth (BlueZ + Blueman).
- Installs GPU drivers (NVIDIA proprietary via nonfree, AMD/Intel via Mesa/Vulkan), and enables `nvidia_drm.modeset=1` in GRUB when NVIDIA is selected.
- Lets you choose a desktop/WM: `i3`, `KDE Plasma`, `river`, `dwm`, `niri`, `Hyprland`, `sway`, `swayfx`, `awesome`, `herbstluftwm`, `XFCE`, `GNOME`, `MATE`.
- Also supports **Hyprland (experimental/beta)** via a third-party repo workaround (see below).
- For Hyprland, the script writes a managed config so the PipeWire stack, portals, and optional Waypaper restore start correctly on Void.
- Generates basic, usable configs for the chosen environment.
- Lets you choose a browser (Firefox, Chromium, Brave, Librewolf).
- Optionally installs Flatpak + Flathub.
- Installs a fairly heavy set of dev tools.
- Installs Neovim and some common GTK/Python deps (`python3-gobject`, `cairo`, `cairo-devel`) when available.
- Installs a baseline set of modern fonts (when available).
- Adds common gaming / 32‑bit libs on x86_64.

> **Warning**  
> This script is intentionally "vibes‑coded": it was written quickly to automate a personal setup and almost certainly contains bugs and sharp edges.  
> **Read the script before running it, and only use it on a fresh system you are comfortable breaking.**

---

## Requirements

- A **Void Linux (runit)** system, preferably fresh.
- Root access (`sudo` or root login).
- Internet connectivity.

The script assumes:

- You’re on a relatively standard Void install with `xbps-install` and runit.
- Your main user account already exists (you’ll be asked for the username).

### Optional: figlet (for a nicer splash screen)

The startup logo is displayed using **figlet** if it is installed, and falls back to built-in Unicode block art if it is not. Figlet is not required to run the installer — it is purely cosmetic.

To install it:

```bash
sudo xbps-install figlet
```

Once installed, the logo will be rendered in figlet’s font instead of the fallback block art.

---

## How to run

From this directory:

```bash
sudo bash ./void-auto-setup.sh
```

Do **not** run it with `sh` or another shell; it relies on Bash features.

---

## Progress display

While it runs, the script shows a **progress bar** (step count + percent) and an **ETA**.

- The progress updates after each major stage completes (repo enablement, core services, audio, DE install, etc.).
- ETA is a rough estimate based on the average duration of completed stages.
- Progress is written to `/dev/tty` when available so it stays visible even though output is also logged via `tee`.

The script logs to:

```text
/var/log/void-auto-setup.log
```

---

## What it asks you

1. **Target user**  
   - Your main non‑root username (e.g. `niklas`).  
   - The script will fail early if the user does not exist.

2. **Seat management stack**
   - `elogind` (default): works well with KDE/SDDM and most setups.
   - `seatd`: lighter, good for Wayland compositors.
   - If you choose `sddm`, the script automatically switches to `elogind` to avoid common VT/xauth failures.
   - If you choose `Hyprland`, the script also forces `elogind` for better stability on Void.

3. **Desktop / WM**
   - `i3` (default, X11)
   - `KDE Plasma`
   - `river` (Wayland)
   - `dwm` (X11)
   - `niri` (Wayland; may require repo support)
   - `Hyprland` (Wayland; **EXPERIMENTAL/BETA** workaround via `Encoded14/void-extra`)
   - `sway` (Wayland)
   - `swayfx` (Wayland)
   - `awesome` (X11)
   - `herbstluftwm` (X11)
   - `XFCE` (X11)
   - `GNOME`
   - `MATE` (X11)

4. **Login manager**
   - `sddm` (default)
   - `lightdm`
   - `greetd` + `tuigreet`
   - `none` (you will use `startx`/TTY)

5. **Browser**
   - `firefox` (default)
   - `chromium`
   - `brave-browser`
   - `librewolf` (if available)

6. **GPU driver preference**
   - `auto` (detect via `lspci`)
   - `nvidia`
   - `amd`
   - `intel`

7. **Optional features**
   - Install common fonts (DejaVu + Noto + Nerd Fonts if available).
   - Flatpak + Flathub.
   - Fastfetch (for the vibes), if available in your repos.
   - Steam (if available).
   - Some AMD Vulkan extras (AMDVLK).

8. **UX choices**
   - App launcher (X11: rofi/dmenu; Wayland: wofi/fuzzel).
   - Optional wallpaper GUI manager (X11: nitrogen/waypaper; Wayland: azote/waypaper), depending on what you picked.
   - If `waypaper` is selected, the script also asks for a backend (for example `swaybg`, `swww`, `feh`, `xwallpaper`, `wallutils`, `hyprpaper`, `mpvpaper`).
   - On Hyprland, choosing `waypaper` forces the `swww` backend and writes the requested dual-monitor layout (`DP-1` 4K at 1.5x, `DP-2` ultrawide at 144Hz) plus `swww-daemon` and `waypaper --restore` autostarts.
   - File manager (Dolphin, Nemo, Thunar, PCManFM, or none).

All prompts have a default value; pressing **Enter** keeps the default.

---

## What it installs (high‑level)

- **Core**: `dbus`, `polkit`, `elogind` or `seatd`.
- **Audio**: `pipewire`, `wireplumber`, `pulseaudio-utils`, `alsa-utils`, `pavucontrol`, plus `libspa-bluetooth` when present.
- **Bluetooth**: `bluez`, `blueman`, runit service `bluetoothd`.
- **GPU**:
  - NVIDIA: `nvidia`, `nvidia-libs-32bit` (when available), and GRUB KMS enablement (`nvidia_drm.modeset=1`) when `/etc/default/grub` is present.
  - AMD / Intel: Mesa + Vulkan stack; optional `amdvlk` for AMD.
  - If no suitable GPU can be detected (no `lspci`, empty output, or unknown vendor), the script **skips GPU driver installation** and prints a warning telling you to install drivers manually.
- **Desktops/WMs** (depending on choice):
  - `i3` + basic `i3status`, `dmenu`, `picom`, `feh`, `alacritty`.
  - `plasma-desktop` or `kde5` meta‑package, `konsole`, `dolphin` (when available).
  - `dwm` + `sxhkd` starter keybinds + terminal fallback launcher (`st`/`alacritty`/`xterm`).
  - `awesome` + basics.
  - `herbstluftwm` + basics.
  - `river`, `niri`, `sway`, or `swayfx` with basic tooling (`foot`, `wofi`, `swaybg`, `grim`, `slurp`, `wl-clipboard`).
  - `XFCE`, `GNOME`, and `MATE` desktop environments.
  - `Hyprland` (experimental) with the tutorial’s support stack: `xorg-server-xwayland`, `wofi`, `Waybar`, `mako`, `kitty`, `grim`, `slurp`, `wl-clipboard`, `polkit-gnome`, and the portal set.
- **Panels/bars**:
  - X11 installs include `polybar`.
  - Wayland installs include `Waybar` (with lowercase `waybar` fallback handled by the generated launcher).
- **Login managers**: `sddm`, `lightdm` (+ GTK greeter), or `greetd` + `tuigreet`.
  - For `sddm`, the script also ensures `xorg-minimal` + `xauth` and writes an explicit `DisplayServer=x11` drop-in.
- **Dev tools**: `base-devel`, VCS tools, build tools, and debuggers.
- **Fonts** (when available): `dejavu-fonts-ttf` (or `xorg-fonts`), `noto-fonts-ttf`, `noto-fonts-cjk`, `noto-fonts-emoji`, `nerd-fonts`.
- **Wallpaper**:
  - Repo sample wallpaper: `wallpaper/sample.jpg`
  - Installed to: `/usr/share/backgrounds/void-auto-setup/sample.jpg`
  - Configs are generated to use that wallpaper by default (X11 via `feh`, Wayland via `swaybg`).
  - For X11 sessions created by this script (i3/dwm/Plasma/awesome/herbstluftwm/XFCE/GNOME/MATE), the session entrypoints are wrapped so the wallpaper is re-applied on each login/boot.
  - Optional wallpaper manager choices include `nitrogen`, `azote`, and `waypaper`.
  - If `waypaper` is selected, the script installs `pipx`, the Void build deps needed for PyGObject/Cairo (`base-devel`, `pkg-config`, `python3-devel`, `cairo-devel`, `gobject-introspection`), required Python deps (GObject/imageio/imageio-ffmpeg/screeninfo/platformdirs variants when available), one selected backend, and installs `waypaper` into the target user’s `pipx` environment.
  - On Hyprland, `waypaper` uses `swww`, and the generated `~/.config/hypr/hyprland.conf` includes the requested monitor matrix, `swww-daemon`, and restore autostart.
  - PipeWire, `pipewire-pulse`, and WirePlumber autostart via `~/.config/autostart/` symlinks to packaged desktop entries when available, and the generated Wayland compositor configs also start that full stack in-session.
  - The script also links `/usr/share/examples/pipewire/20-pipewire-pulse.conf` and `/usr/share/examples/wireplumber/10-wireplumber.conf` into `~/.config/pipewire/pipewire.conf.d/` when those example files exist.

Font installs are **repo-safe**: the script checks whether each font package exists in XBPS before attempting to install it, so missing font packages won't abort the run.

If you want to tweak font rendering, Void supports enabling fontconfig presets from `/usr/share/fontconfig/conf.avail/` by symlinking them into `/etc/fonts/conf.d/` and then running `xbps-reconfigure -f fontconfig`.
- **Gaming / multilib** (x86_64 only): Mesa/Vulkan 32‑bit libs, optional Steam.

User‑level autostarts for PipeWire/`pipewire-pulse`/WirePlumber and Blueman are configured in `~/.config/autostart` or compositor configs, rather than relying on systemd user services.

---

## Known limitations / caveats

- **Not idempotent**: running it multiple times may be noisy or clobber some simple configs.
- **Hard‑coded defaults**: a lot of package choices and configs are opinionated.
- **Repo expectations**: assumes certain packages exist (`niri`, `kde5`, etc.); if they don’t, the script attempts fallbacks or just warns.
- **Hyprland is a workaround**: Hyprland is installed from the third-party `Encoded14/void-extra` repo when selected. This is **experimental/beta**, may break at any time, and is **not affiliated with Hyprland or Void**.
- **Hyprland launch helper**: the script generates `/usr/local/bin/start-hyprland` (and a `hyprland` alias when needed) and uses that wrapper in the generated Hyprland session entry.
- **Hyprland + SDDM**: when SDDM is selected, the generated Hyprland session entry wraps launch with `dbus-run-session` so the DBus session is initialized reliably.
- **Hyprland extra compatibility**: when Hyprland is selected, the script also attempts to install portal packages including `xdg-desktop-portal-hyprland` when available, and greetd is configured to use `start-hyprland`.
- **Hyprland startup path**: the script writes a managed `~/.config/hypr/hyprland.conf` so the Void-specific PipeWire/portal startup and optional Waypaper monitor profile are applied automatically.
- **Wayland compositors**: configurations are minimal and may not cover all hardware/locale/input edge cases.
- **No shellcheck guarantee**: this script has not been rigorously linted in your environment; read it if you care about safety.

---

## Contributing / modifying

- Read `void-auto-setup.sh` and tweak package lists, configs, or prompts to match your setup.
- If you improve robustness or fix bugs, feel free to version‑control your changes.
- Consider forking before sharing with others; this is tuned for a personal Void workflow.

---

## Disclaimer

See `DISCLAIMER.md` for a more explicit warning, assumptions, and "vibes coded" notes.
See `PHILOSOPHY.md` for the project's motivation and personal context.

---

## License

This project is licensed under the `0BSD` license. See `LICENSE`.

---

## Hyprland (experimental/beta workaround)

If you select Hyprland, this script follows the **prebuilt binaries** method from `Encoded14/void-extra` (not the old/orphaned repo).

- **Not affiliated**: `Encoded14/void-extra` is **not affiliated with or endorsed by the Void Linux project** (per their README).
- **Not affiliated with Hyprland**: this script is not affiliated with or endorsed by Hyprland either.
- **Workaround**: this is a convenience workaround to install Hyprland on Void; treat it as **beta**.

Implementation details:

- Adds `/etc/xbps.d/20-repository-extra.conf` pointing at `raw.githubusercontent.com/Encoded14/void-extra/repository-<arch>` (or `-musl` when detected).
- Runs `xbps-install -S` so you can accept the repository fingerprint.
- Installs `hyprland` if it becomes available in XBPS.
