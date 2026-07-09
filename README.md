# HyperCreditsMenubar

A macOS menu bar application that displays your [Hyper (Charm)](https://hyper.charm.land) credit balance.

![Screenshot placeholder](docs/screenshot-placeholder.png)

## Features

- ⚡ **Menu bar display** — shows `⚡{balance}` (e.g. `⚡42`) right in your menu bar
- 🔄 **Auto-refresh** — fetches your balance every 5 minutes
- 🔒 **Keychain storage** — your API key is stored securely in macOS Keychain
- 🎨 **Color-coded balance** — green (≥100), yellow (10–99), red (<10)
- 🔐 **Secure input** — API key field is masked
- 🚀 **Launch at login** — optional, using `SMAppService`
- 📋 **Quick link** — opens [hyper.charm.land](https://hyper.charm.land) from the menu
- 🫥 **Agent app** — no dock icon, no main window; lives entirely in the menu bar

## Installation

### Download the pre-built release

1. Go to the [Releases page](https://github.com/ilyakooo0/hyper-credits-menubar/releases)
2. Download the latest `HyperCreditsMenubar-*.zip`
3. Unzip and move `HyperCreditsMenubar.app` to `/Applications`
4. Launch the app — it will appear in your menu bar as ⚡

> **Note:** Releases are currently unsigned. On first launch, right-click the app → **Open**, or allow it in **System Settings → Privacy & Security**.

### Set your API key

1. Click the ⚡ icon in your menu bar
2. Enter your Hyper API key (starts with `sk-...`) in the **API Key** field
3. Click **Save**
4. Your balance will appear immediately

You can get your API key from [hyper.charm.land](https://hyper.charm.land).

## Build from source

### Prerequisites

- macOS 14.0+ (Sonoma)
- Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Steps

```bash
# Clone the repository
git clone https://github.com/ilyakooo0/hyper-credits-menubar.git
cd hyper-credits-menubar

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open HyperCreditsMenubar.xcodeproj

# Or build from the command line
xcodebuild \
  -scheme HyperCreditsMenubar \
  -configuration Release \
  -archivePath build/HyperCreditsMenubar.xcarchive \
  archive \
  CODE_SIGNING_ALLOWED=NO
```

### Run tests

```bash
xcodebuild test \
  -scheme HyperCreditsMenubar \
  -configuration Debug \
  -destination "platform=macOS"
```

## Versioning

Versions follow the format `YYYY.MM.DD.HHHH` where `HHHH` is the UTC hour and minute (24-hour).

| Commit time (UTC)        | Version           |
| ------------------------ | ----------------- |
| 2026-07-09 14:23         | `2026.07.09.1423` |
| 2026-01-01 00:00         | `2026.01.01.0000` |
| 2026-12-31 23:59         | `2026.12.31.2359` |

The version is derived automatically from the commit timestamp in the GitHub Actions release workflow.

## Project structure

```
hyper-credits-menubar/
├── project.yml                          # xcodegen project definition
├── HyperCreditsMenubar/
│   ├── HyperCreditsApp.swift            # @main App, NSStatusBar, timer
│   ├── CreditsChecker.swift             # API client (GET /v1/credits)
│   ├── MenuView.swift                   # SwiftUI popover view + ViewModel
│   ├── KeychainHelper.swift             # Keychain wrapper for API key
│   ├── VersionFormatter.swift           # YYYY.MM.DD.HHHH formatting
│   ├── Info.plist                       # LSUIElement=true (agent app)
│   ├── HyperCreditsMenubar.entitlements # Network client entitlements
│   └── Assets.xcassets/                 # App icon, accent color
├── HyperCreditsMenubarTests/
│   ├── CreditsCheckerTests.swift        # JSON decoding tests
│   └── VersionFormatterTests.swift      # Version formatting tests
├── .github/workflows/
│   └── release.yml                      # Build + release on push to master
├── README.md
├── LICENSE
└── .gitignore
```

## How it works

1. **Menu bar item**: The app creates an `NSStatusItem` with a variable-length button showing `⚡{balance}` or `⚡?`.
2. **Popover**: Clicking the menu bar item shows an `NSPopover` containing a SwiftUI `MenuView`.
3. **API client**: `CreditsChecker` performs `GET https://hyper.charm.land/v1/credits` with `Authorization: Bearer {apiKey}` and decodes `{"balance": <int>}`.
4. **Keychain**: The API key is stored/retrieved via `KeychainHelper` using the macOS Security framework.
5. **Timer**: A `Timer` fires every 5 minutes to refresh the balance.
6. **Agent app**: `LSUIElement=true` in `Info.plist` makes the app a background agent — no dock icon, no main window.

## Credits

- **Author**: Ilya Koo ([@ilyakooo0](https://github.com/ilyakooo0))
- **API**: [Hyper by Charm](https://hyper.charm.land)
- **Built with**: Swift 5.9, SwiftUI, macOS 14+

## License

MIT — see [LICENSE](LICENSE).
