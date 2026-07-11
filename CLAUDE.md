# HyperCreditsMenubar

## Architecture
macOS menu bar app (SwiftUI, macOS 14+) showing Hyper (Charm) credit balance.
- `HyperCreditsApp.swift` — @main App, NSStatusBar, timer, sleep/wake, popover
- `ViewModel.swift` — Observable state: balance, refresh, notifications, history
- `MenuView.swift` — SwiftUI popover view (balance, sparkline, settings)
- `CreditsChecker.swift` — API client for `GET https://hyper.charm.land/v1/credits`
- `KeychainHelper.swift` — Keychain wrapper (KeychainStore + KeychainHelper)
- `VersionFormatter.swift` — Version string formatting

## Build
- Uses [xcodegen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is source of truth
- `xcodegen generate` creates the .xcodeproj (not committed)
- Build: `xcodebuild -scheme HyperCreditsMenubar -configuration Debug build`
- Test: `xcodebuild test -scheme HyperCreditsMenubar -configuration Debug -destination "platform=macOS"`
- Swift 5.9, macOS 14.0 deployment target

## Conventions
- Clean minimal UI — big hero number, generous spacing, restrained color, no chrome
- No card-heavy/multi-material/gradient-rich designs
- Rounded font family at 4 sizes (hero/section/control/caption/footnote)
- Monospaced digits for numbers that change
- Tests use StubURLProtocol for network mocking, FakeKeychain for keychain mocking
- The app is an agent app (LSUIElement=true) — no dock icon, no main window

## VCS
- jj colocated with git
- Push directly to master — no PRs for this repo
