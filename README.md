[English](README.md) | [한국어](README.ko.md) | [日本語](README.ja.md) | [简体中文](README.zh-Hans.md)

# macssential

macssential is a menu bar utility for macOS 14+ that lets you take control of
inconvenient macOS defaults with a single click — dock behavior across
monitors, keyboard repeat speed, scroll direction, filename normalization, and
more. Each feature is an independent module you can switch on or off right
from the menu bar, with no digging through System Settings.

> macssential is open source under the [MIT License](LICENSE).

## Features

- **Dock Anchor** — Lock the Dock to a specific monitor so it stops jumping
  between displays.
- **Dock Auto-Hide** — Automatically hide and show the Dock.
- **Hide Recent Apps** — Remove the recently used apps section from the Dock.
- **Hidden Files** — Show hidden files in Finder.
- **Key Repeat** — Faster keyboard repeat than System Settings allows.
- **Scroll Direction** — Set mouse and trackpad scrolling directions
  independently.
- **Screenshot Auto-Copy** — Copy screenshots straight to the clipboard
  instead of saving files to the Desktop.
- **Filename Normalizer** — Automatically rename decomposed (NFD) filenames
  to NFC, fixing garbled-looking names for Korean, Japanese, and other
  languages.

## Using the App

**Menu bar panel.** Click the ✱ icon in the menu bar to open the dropdown
panel. Toggle features on or off with a click — enabled modules show their
controls (sliders, options) right inside the panel.

**Settings window.** Click the Settings (gear) button at the bottom of the
panel to open the Settings window. It has four tabs: General, Modules, Panel,
and About. The Modules tab enables or disables modules app-wide.

**Customizing the panel.** Use the Panel tab to choose exactly which modules
appear in the menu bar panel, so it only shows what you actually use.

## Install

### Homebrew

```sh
brew tap luxurycarrot/tap
brew install macssential
```

(One-time `brew tap` registers the tap; recent Homebrew versions may ask you
to confirm trusting it. After that, `brew install macssential` and
`brew upgrade macssential` work with the short name.)

Or as a one-liner:

```sh
brew install --cask luxurycarrot/tap/macssential
```

### Direct download

1. Download the latest DMG from the
   [Releases page](https://github.com/LuxuryCarrot/macssential/releases).
2. Open the DMG and drag `macssential.app` into your `Applications` folder.
3. Launch macssential — it appears in your menu bar.

## Updates

macssential updates itself automatically via
[Sparkle](https://sparkle-project.org/). The app checks the update feed at
`https://luxurycarrot.github.io/macssential/appcast.xml` and offers
new versions in-app — no manual downloads needed.

## Permissions

Dock Anchor, Scroll Direction, and Screenshot Auto-Copy require the
Accessibility permission. Grant it in **System Settings > Privacy & Security >
Accessibility** — the app will guide you there when needed. The other modules
work without any special permissions.

## Requirements

- macOS 14 Sonoma or later
