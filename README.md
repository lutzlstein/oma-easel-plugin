# Oma Easel for the Omarchy bar

[![Built for Omarchy | Plugin](https://img.shields.io/badge/Built_for_Omarchy-Plugin-blue)](https://omarchy.org)

A bar widget for [Oma Easel](https://github.com/lutzlstein/oma-easel), the Omarchy app that generates new backgrounds for your themes, and a background renderer that shows each of your screens its own version of a background.

- Click to open Oma Easel, or switch to it when it's already open.
- While images generate, the widget shows progress (`󰏘 1/3`), and the tooltip names the theme.
- If Oma Easel isn't installed, the widget is dimmed and clicking it opens a terminal that installs the latest release with `sudo pacman -U`.

## Per-screen backgrounds

Oma Easel can make versions of a background for your other screen shapes, say a 9:16 version for a rotated monitor beside a 21:9 ultrawide. A version has the background's name, in a folder named for the shape:

```
~/.config/omarchy/backgrounds/<theme>/7-add-boat.webp
~/.config/omarchy/backgrounds/<theme>/9x16/7-add-boat.webp
```

Omarchy's own renderer shows one image on every screen. While this plugin is enabled, its renderer takes Omarchy's place: each screen shows the version closest to its shape, or the background itself when that fits better. With no versions, it behaves exactly like Omarchy's. Theme switches, `omarchy theme bg set`, and the background cycle work as before; the cycle reads only the top folder, so versions never show up in it on their own.

The renderer is Omarchy's `omarchy.background` with these changes, and it keeps the same `background` IPC target. It adds four calls:

| Call | Does |
|---|---|
| `omarchy-shell background rescanVersions` | Looks for new versions, after one is saved |
| `omarchy-shell background setScreen <screen> <path>` | Shows an image on one screen only, for previews |
| `omarchy-shell background clearScreens` | Ends those previews |
| `omarchy-shell background shown` | Prints what each screen shows, as `name<TAB>path` lines |

Removing or disabling the plugin gives the background back to Omarchy's renderer. The renderer and the widget come as one plugin, so turning one off turns off both.

## Install

This plugin is a companion to a native app, so it takes two steps:

```sh
sudo pacman -U https://github.com/lutzlstein/oma-easel/releases/latest/download/oma-easel-x86_64.pkg.tar.zst
omarchy plugin add https://github.com/lutzlstein/oma-easel-plugin --enable
```

The first installs the app from its latest GitHub release, pulling its dependencies from the Arch repos: `qt6-base`, `qt6-declarative`, `qt6-wayland`, `imagemagick`, `xdg-desktop-portal`, `libsecret`, and optionally `codex`. The second adds the bar widget. Installing the plugin first also works: the widget offers the app's install command when you click it.

## What it reads and runs

The widget:

- Reads `$XDG_RUNTIME_DIR/oma-easel/status.json`, which the app writes while it's open: the app's pid, the theme, and how many images are generating. Nothing else.
- Runs `oma-easel`, `hyprctl dispatch` (to focus the app's window), `test -d /proc/<pid>` (to ignore a status file left by a crash), `command -v oma-easel`, and, only when you click it while the app is missing, `omarchy-launch-floating-terminal-with-presentation "sudo pacman -U https://github.com/lutzlstein/oma-easel/releases/latest/download/oma-easel-x86_64.pkg.tar.zst"`.

The renderer:

- Reads the current background and theme from `~/.local/state/omarchy/current/`, and lists the shape folders in `~/.config/omarchy/backgrounds/<theme>/` and the theme's own `backgrounds/`.
- Runs `readlink`, `find`, and `magick identify -ping` (to read image sizes), as Omarchy's renderer does.

Neither has network access, credentials, or privileged commands of its own. Installing the app asks for your password through the package manager, in a terminal you can read.

## Remove

```sh
omarchy plugin remove io.github.lutzlstein.oma-easel
```

The app stays installed; remove it with `sudo pacman -R oma-easel` if you want.

## License

MIT. `Background.qml` is based on Omarchy's background renderer, also MIT; its notice is in [LICENSE-omarchy](LICENSE-omarchy).
