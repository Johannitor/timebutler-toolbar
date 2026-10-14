# Timebutler Toolbar

[![Tests](https://github.com/Johannitor/timebutler-toolbar/actions/workflows/tests.yml/badge.svg)](https://github.com/Johannitor/timebutler-toolbar/actions/workflows/tests.yml)

A small, native macOS menu bar app for the [Timebutler](https://www.timebutler.com) time clock. You can clock in, take breaks and clock out without opening the browser. It also keeps your working time visible in the menu bar.

Built with Swift 6 and SwiftUI. It talks to the official Timebutler API v2 using your personal access token.

> [!IMPORTANT]
> **This is an unofficial, community project.** It is not affiliated with, endorsed by or supported by Timebutler or its operators. "Timebutler" is a trademark of its respective owner and is used here only to describe what this app works with. Please don't contact Timebutler support about this app.

> [!NOTE]
> The app's user interface is in **German**, like Timebutler's main audience. Code, comments and documentation are in English.

## Features

- **Clock in, start/end a break, clock out or discard a shift** straight from the menu bar
- **Net working time in the menu bar** (`H:MM`), even while the panel is closed
- **Detail panel** with work and break time of the current shift, plus today's total with target, remaining time and overtime
- **Day timeline**: work, breaks and untracked gaps since your first clock-in, scaled to your target time plus the required break, with a marker when you go over
- **Confirmation before clocking out or discarding**. When Timebutler applies its break rules, you choose right in the panel (accept the correction or save unchanged)
- **Break reminders under German working-time law (ArbZG)**: 15 minutes before 6 h or 9 h of work, if you have not yet logged 30 or 45 minutes of break
- **Notifications** when you reach your target time, and a warning 15 minutes before the 10-hour daily limit. Each can be turned off on its own
- **Optional automatic break end**: start a 30, 45 or 60 minute break that ends on its own (off by default)
- **Launch at login** (optional)
- **Token stored in the macOS Keychain**, on this device only, never logged

## Requirements

- macOS 15 or later
- A recent Xcode (developed with Xcode 27)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- A Timebutler account with time tracking enabled and permission to create a personal API token

There are no prebuilt releases yet. You build the app yourself, which takes about a minute.

## Installation

```sh
git clone https://github.com/Johannitor/timebutler-toolbar.git
cd timebutler-toolbar
brew install xcodegen
scripts/install.sh
```

The script generates the Xcode project, builds a Release version, copies `TimebutlerToolbar.app` to `~/Applications` and launches it. "Launch at login" only works reliably when the app is in `~/Applications` or `/Applications`.

### Code signing

By default the app is signed **ad hoc**, so no Apple Developer account is needed. The downside is that macOS may ask again for Keychain access after each rebuild, because the signature changes.

To sign with your own Apple team (a free personal team is enough), create a git-ignored local config:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
# then set DEVELOPMENT_TEAM to your team ID
```

Your team ID is shown in Xcode under *Settings → Accounts*. `Config/Local.xcconfig` is listed in `.gitignore`, so your team ID is never committed.

## Setting up your token

1. Create a personal token in Timebutler: <https://app.timebutler.com/do?ha=personaltoken&ac=1>. You can also use the "Token in Timebutler erstellen" button in the app.
2. On first launch the settings window opens. Paste the token (`tb_…`) and click "Prüfen & speichern".
3. The app checks the token against the API and saves it to the Keychain only if the check succeeds.

Treat the token like a password: it grants access to your Timebutler data. You can revoke it in Timebutler at any time.

## Development

```sh
xcodegen generate
xcodebuild test -project TimebutlerToolbar.xcodeproj -scheme TimebutlerToolbar -destination 'platform=macOS'
```

Or open `TimebutlerToolbar.xcodeproj` in Xcode after `xcodegen generate`. The `.xcodeproj` is generated from `project.yml` and is not checked in.

The tests use Swift Testing and rely only on mocks: they never call the real API and never touch the real Keychain. GitHub Actions runs them on every pull request.

### Project layout

| Path | Contents |
| --- | --- |
| `TimebutlerToolbar/API/` | HTTP client, DTOs and error mapping for the Timebutler API v2 |
| `TimebutlerToolbar/Model/` | `ShiftSnapshot` (time calculations), `DayTimeline`, `ShiftStore` (app state) |
| `TimebutlerToolbar/Services/` | Break reminders, launch at login |
| `TimebutlerToolbar/Storage/` | Keychain token storage |
| `TimebutlerToolbar/UI/` | Thin SwiftUI views (menu bar label, panel, settings) |
| `TimebutlerToolbarTests/` | Unit tests |
| `Config/` | Signing configuration |
| `docs/IMPLEMENTATION_PLAN.md` | Original design notes, including API behaviour verified against the live service |

## Known limitations

- The API does not return individual breaks, only totals and the current break. In the day timeline, breaks of saved entries are therefore drawn in the middle of their block. Only the running break is placed exactly.
- Project and category are not supported when clocking out; the app clocks out without them.
- "Heute" (today) is based on the work summary, which only includes saved entries, plus the running shift.
- The automatic break end only works while the app is running. If the Mac sleeps past the end, the break ends when it wakes up, because the API cannot backdate it.
- Actions that Timebutler only allows at a terminal are disabled.

## Contributing

Issues and pull requests are welcome. Please run the tests before opening a pull request. To report a security problem, please follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## License

Source-available under the [MIT License with the Commons Clause](LICENSE). You may use, modify and share the app free of charge, including at work. You may **not sell it**, or sell a product or service whose value comes mainly from it. Because of that restriction, this is not "open source" in the OSI sense.
