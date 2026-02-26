## Disclaimer / Vibes Notice

This repository contains `void-auto-setup.sh`, a **vibes‑coded** post‑install script for Void Linux (runit).

It was written to automate a personal setup quickly, not as a polished, production‑grade installer.

Some assets (like the included sample wallpaper at `wallpaper/sample.jpg`) are **AI-generated** purely as placeholders.

If you select Hyprland, the script may add a third‑party XBPS repo (`Encoded14/void-extra`) as a workaround. This repository is not affiliated with Void, and this script is not affiliated with Hyprland.

---

### Things you should assume

- **There are bugs.** Some paths, packages, or services may be wrong for your snapshot of the Void repos.
- **Configs are opinionated.** The generated i3, river, niri, etc. configs reflect personal taste, not best practices.
- **It may break your system.** Misconfigured GPU drivers, login managers, or seat management can lead to no‑GUI boots or other unpleasantness.
- **It targets fresh installs.** Running this on an already customized system may conflict with your existing configs or packages.
- **It assumes runit Void.** On anything else, it is likely to fail in creative ways.

---

### What you should do before running it

- **Read the script (`void-auto-setup.sh`) end‑to‑end.**  
  Make sure you understand what it installs, what services it enables, and which config files it writes.
- **Decide if the opinions match your own.**  
  If they don't, edit the script to fit your preferences first.
- **Be prepared to debug.**  
  Have a TTY, live USB, or chroot plan in case display/login breaks.

---

### No warranty

This script is provided **as‑is, with no warranty of any kind**.  
Use it entirely at your **own risk**. If it eats your system, you keep both pieces.

That said, if you discover clear bugs and want to fix them, patches are welcome—and so are your own forks and remixes.

