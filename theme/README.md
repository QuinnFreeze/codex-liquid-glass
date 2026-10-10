# Codex Liquid Glass · macOS Theme

Adds black-and-white wallpaper, a glass composer, floating panels, and a continuous background to the macOS Codex desktop app. The theme follows the app's light or dark appearance, preserves native thin scrollbars, button state colors, and fonts, and respects Reduce Transparency and Reduce Motion.

Styles load through external runtime scripts and a local debugging interface. Installation does not modify the official app bundle or its signed files.

## Requirements

- macOS 13 or later, with the official Codex desktop app already installed.
- Node.js 22 or later with built-in `WebSocket` support. Scripts prefer `node` from `PATH`, then try the runtime bundled with the app.
- An available `python3`; no additional Python packages or npm dependencies are needed.
- Xcode Command Line Tools: the installer uses `/usr/bin/clang` to compile the Objective-C launcher and observer.

If Command Line Tools are not installed, run `xcode-select --install` and complete the system installation process first. App discovery supports `/Applications/Codex.app` and `/Applications/ChatGPT.app`, and checks the bundle ID `com.openai.codex`.

## Install and Launch

Open a terminal at the repository root and run:

```zsh
cd theme
./scripts/install
```

The default installer creates backups before it:

1. Copies the theme to `$HOME/Library/Application Support/CodexTheme`.
2. Creates a separate launcher at `$HOME/Applications/Codex Liquid Glass.app`.
3. Installs and loads the `local.wynn.codex-liquid-glass` LaunchAgent to observe app launches and window changes.
4. Replaces the official Codex Dock entry with the theme launcher, or adds a theme entry if none exists, and saves restoration records.

Finish your current conversation, quit Codex normally, then launch **Codex Liquid Glass** from the Dock. The launcher opens the official app with local debugging arguments, and the observer automatically attaches to its windows.

An app already running without a debugging port cannot receive additional launch arguments; the installer will not forcibly end the current conversation. If you opened the official app directly and want the theme, quit normally and reopen it through the theme launcher.

## Configure and Reapply

After installation, edit `settings.json` and `styles/` in the installed directory. The repository copies are for source maintenance; editing them does not automatically overwrite the installed files.

```zsh
open -e "$HOME/Library/Application Support/CodexTheme/settings.json"
"$HOME/Library/Application Support/CodexTheme/scripts/reapply"
```

| Setting | Default | Purpose |
|---|---|---|
| `wallpaper` | `wallpaper/current.jpg` | JPG, PNG, or WebP path relative to the theme directory |
| `position` | `60% 42%` | Wallpaper position with cover sizing; two percentages |
| `mainAlpha` | `0.08` | Light-mode main background opacity |
| `sidebarAlpha` | `0.72` | Light-mode sidebar background opacity |
| `scrimAlpha` | `0.22` | Reading scrim that fades from left to right |
| `messageAlpha` | `0.90` | Message background opacity |
| `activityAlpha` | `0.78` | Tool activity background opacity |
| `floatingAlpha` | `0.86` | Light-mode composer and menu background opacity |
| `floatingBlur` | `7` | Blur radius for small floating panels, in px |
| `sidebarBlur` | `4` | Retained for older settings; dynamic sidebar blur is currently disabled |
| `refraction` | `false` | Edge refraction toggle for small menus |

Opacity values range from `0–1`, and blur radii from `0–24`. Dark mode has separate opacity overrides; accessibility settings take precedence. Missing `scrimAlpha` or `activityAlpha` values use their defaults.

To change the wallpaper, place the image in the installed `wallpaper/` directory, update the `wallpaper` field, and reapply. `original.jpg` preserves the original image; `current.jpg` is currently used.

## Uninstall and Backups

Run the uninstall entry point in the installed directory:

```zsh
"$HOME/Library/Application Support/CodexTheme/scripts/uninstall"
```

Uninstalling stops the theme service, removes automatic attachment, restores the Dock entries managed by the theme, and removes the theme launcher. Settings, theme files, wallpaper, and backups are preserved. Then quit Codex normally and open the official app to close the debugging port enabled by the theme launcher.

Integration backups from installation and removal are stored in `$HOME/Library/Application Support/CodexThemeBackups/`. File backups made by manual reapplication are stored in the installed theme directory's `backups/`. Keep any backups you may need for restoration.

## Verification and Compatibility

The previous verification environment was **Codex 26.930.61225 on Intel macOS**. Recorded checks cover light, dark, and system appearance switching; window reloads; new windows; cold starts in an isolated instance; service recovery; sidebar scrolling; the composer; and tooltip text. Some viewport and accessibility checks used Chromium emulation.

This GitHub upload preparation checked only documentation and existing files. It did not include reinstallation, removal, or a full quit-and-relaunch test of the main app. Apple Silicon, later Codex versions, and system restarts have not been verified. Changes to the app's native DOM may require CSS adjustments.

The theme uses the local debugging interface at `127.0.0.1:9236` and verifies that the listening process belongs to the official app. Use it only in a trusted local environment; do not forward or expose this port.

## Sources

Styling ideas draw on [Fei-Away/Codex-Dream-Skin](https://github.com/Fei-Away/Codex-Dream-Skin), reference commit `6f72d849e8de36aa7eef6bca9f2634e96b5706f7`, particularly directional scrims, single-layer composer rendering, and separate light and dark background colors. That project's installer was not run.

The source and redistribution rights of the included wallpaper have not been documented. This repository declares no wallpaper license. Confirm the relevant rights before using or redistributing the images.
