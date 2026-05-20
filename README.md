# Notchprompt Pro (Fork)

> **This is a fork** of [saif0200/notchprompt](https://github.com/saif0200/notchprompt) by Saif (MIT licensed) — all credit for the original goes to upstream.
>
> **What's different in this fork:**
> - Hardened screen-share invisibility (extra `NSPanel` config + documented test matrix)
> - Customizable global hotkeys ([sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts))
> - Multi-script library (save / load / switch between scripts)
> - Themes (dark / light / high-contrast / reading-line)
> - Pause-on-punctuation
> - **Auto-sync speech follow** (the killer feature — on-device `SFSpeechRecognizer`, teleprompter scrolls as you speak, current word highlighted)
>
> Bundle id: `com.gabrielfranklin.notchpromptpro`. Marketing version: `1.2.0-pro`.

<p align="center">
  <img src="assets/banner.png" alt="Notchprompt Banner" width="100%">
</p>

Native macOS notch-adjacent teleprompter for presentations and recordings.

## Quick Demo

> Demo assets below are placeholders. Replace with real captures before public
> launch.

<!--
![Notchprompt hero screenshot](docs/media/hero.png)
*Hero view of the overlay panel and settings workflow.*

![Notchprompt scrolling demo GIF](docs/media/notchprompt-demo.gif)
*In-use scrolling demo with start/pause and speed adjustments.*
-->

## Features

- Menu bar utility workflow (`NP` status item).
- Notch-adjacent floating overlay with transport controls.
- Start/pause, reset, and jump back 5 seconds.
- Adjustable speed, font size, overlay width, and overlay height.
- Optional countdown before scrolling starts.
- Import/export plain text scripts.
- Privacy mode (`NSWindow.SharingType`, best-effort/app-dependent).

## Requirements

- macOS version supported by the current deployment target in
  `notchprompt.xcodeproj`.
- Apple Silicon or Intel Mac.

## Install (Recommended)

1. Open GitHub Releases:
   `https://github.com/gabrielfranklin77/notchprompt/releases` (this fork)
   or `https://github.com/saif0200/notchprompt/releases` (upstream)
2. Download the latest `.dmg` release asset.
3. Open the DMG and drag `notchprompt.app` to `Applications`.
4. Launch `notchprompt.app`.

### Unsigned Build Note

This build is currently unsigned/unnotarized, so macOS may show security prompts.

If macOS shows:

- `Apple could not verify "notchprompt" is free of malware...`
- or `"notchprompt" is damaged and can’t be opened`

run:

```bash
xattr -cr /Applications/notchprompt.app
open /Applications/notchprompt.app
```

If it is still blocked:

1. Open `System Settings -> Privacy & Security`.
2. Click **Open Anyway** for `notchprompt`.
3. Launch again.

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `⌥⌘P` | Start / Pause |
| `⌥⌘R` | Reset scroll |
| `⌥⌘J` | Jump back 5s |
| `⌥⌘H` | Toggle Privacy Mode |
| `⌥⌘=` | Increase speed |
| `⌥⌘-` | Decrease speed |

## Build From Source

```bash
git clone https://github.com/gabrielfranklin77/notchprompt.git
cd notchprompt
open notchprompt.xcodeproj
```

CLI build:

```bash
xcodebuild -project notchprompt.xcodeproj -scheme notchprompt -configuration Debug build
```

## License

MIT. See `LICENSE`.
