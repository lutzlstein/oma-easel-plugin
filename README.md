# Oma Easel for the Omarchy bar

[![Built for Omarchy | Plugin](https://img.shields.io/badge/Built_for_Omarchy-Plugin-blue)](https://omarchy.org)

A bar widget for [Oma Easel](https://github.com/lutzlstein/oma-easel), the Omarchy app that generates new backgrounds for your themes.

- Click to open Oma Easel, or switch to it when it's already open.
- While images generate, the widget shows progress (`󰏘 1/3`), and the tooltip names the theme.
- If Oma Easel isn't installed, the widget is dimmed and clicking it opens a terminal that installs the latest release with `sudo pacman -U`.

## Install

This plugin is a companion to a native app, so it takes two steps:

```sh
sudo pacman -U https://github.com/lutzlstein/oma-easel/releases/latest/download/oma-easel-x86_64.pkg.tar.zst
omarchy plugin add https://github.com/lutzlstein/oma-easel-plugin --enable
```

The first installs the app from its latest GitHub release, pulling its dependencies from the Arch repos: `qt6-base`, `qt6-declarative`, `qt6-wayland`, `imagemagick`, `xdg-desktop-portal`, `libsecret`, and optionally `codex`. The second adds the bar widget. Installing the plugin first also works: the widget offers the app's install command when you click it.

## What it reads and runs

- Reads `$XDG_RUNTIME_DIR/oma-easel/status.json`, which the app writes while it's open: the app's pid, the theme, and how many images are generating. Nothing else.
- Runs `oma-easel`, `hyprctl dispatch` (to focus the app's window), `test -d /proc/<pid>` (to ignore a status file left by a crash), `command -v oma-easel`, and, only when you click it while the app is missing, `omarchy-launch-floating-terminal-with-presentation "sudo pacman -U https://github.com/lutzlstein/oma-easel/releases/latest/download/oma-easel-x86_64.pkg.tar.zst"`.
- No network, credentials, or privileged commands of its own. Installing the app asks for your password through the package manager, in a terminal you can read.

## Remove

```sh
omarchy plugin remove io.github.lutzlstein.oma-easel
```

The app stays installed; remove it with `sudo pacman -R oma-easel` if you want.

## License

MIT
