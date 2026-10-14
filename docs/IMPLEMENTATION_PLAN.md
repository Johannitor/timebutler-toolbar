# Timebutler Toolbar – Implementation Plan

A native macOS menu bar app (Swift 6, SwiftUI) for a single employee to use the Timebutler time clock ("Stempeluhr") via the Timebutler API v2 with a personal access token.

The full OpenAPI spec is saved at `docs/timebutler-openapi.json`. This document is the source of truth wherever it disagrees with the spec, because some behaviour below was **verified against the live API** and differs from the docs.

---

## 1. Decisions (already confirmed with the user, do not change)

| Topic | Decision |
|---|---|
| Platform | macOS 15.0+ deployment target (dev machine: macOS 26.6, Xcode 27, Swift 6.4). Apple Silicon. |
| Project | XcodeGen (`project.yml`, installed at `/opt/homebrew/bin/xcodegen`). The generated `.xcodeproj` is git-ignored. |
| Signing | Automatic signing, team `<TEAM_ID>`. Build with `-allowProvisioningUpdates`. Bundle ID `de.lochimbaum.TimebutlerToolbar`. |
| UI language | **German only**. All user-facing strings are German; code and comments are English. |
| Menu bar label | SF Symbol plus net working time as `H:MM` (e.g. `3:42`) while running, paused or waiting. Icon only when idle. |
| Token | Pasted into a Settings window, validated against the API, and stored in the **Keychain**. Never in UserDefaults, never logged. |
| Extras | (a) Launch at login toggle, (b) confirm before *Ausstempeln* and *Abbrechen*, (c) ArbZG break reminder notifications, (d) "today's total" in the detail panel. |
| Clock-out | User never picks project, category or remarks. `stop` is sent **without body**. No project or category pickers. |
| Dock | No Dock icon (`LSUIElement = YES`). |

## 2. API facts (verified)

Base URL: `https://app.timebutler.com/api/v2`. Every request sends:
- `Authorization: Bearer <token>`. Tokens look like `tb_…` and should be trimmed of whitespace.
- `Accept: application/json`
- `User-Agent: TimebutlerToolbar/<version>`

Endpoints used:

| Purpose | Request | Success |
|---|---|---|
| Current state | `GET /time-clock/status` | 200 `TimeClockStatusDto` |
| Clock in | `POST /time-clock/start` (no body) | 200 `TimeClockStatusDto` |
| Start break | `POST /time-clock/pause` (no body) | 200 `TimeClockStatusDto` |
| End break | `POST /time-clock/resume` (no body) | 200 `TimeClockStatusDto` |
| Clock out | `POST /time-clock/stop` (no body on first call; see §2.3) | 200 `TimeClockStopResponse`, or **204** (was `waiting` → discarded) |
| Discard shift | `POST /time-clock/cancel` (no body) | 200 `TimeClockStatusDto` (status `idle`) |
| Validate token / name | `GET /user/profile` | 200 `UserProfileResponse` |
| Today's totals | `GET /time-tracking/work-summary` | 200 `WorkSummaryResponse` |

### 2.1 Real response samples (use these verbatim as test fixtures)

Running:
```json
{"status":"running","startTimestamp":1791911608634,"workTimeElapsedSeconds":60,"breakElapsedSeconds":0,"accumulatedBreakSeconds":0,"isBusinessTripActive":false,"startOnlyOnTerminal":false,"pauseOnlyOnTerminal":false,"stopOnlyOnTerminal":false}
```
Paused (11 s into a break):
```json
{"status":"paused","startTimestamp":1791911608634,"pauseTimestamp":1791911719831,"workTimeElapsedSeconds":111,"breakElapsedSeconds":11,"accumulatedBreakSeconds":0,"isBusinessTripActive":false,"startOnlyOnTerminal":false,"pauseOnlyOnTerminal":false,"stopOnlyOnTerminal":false}
```
Running again after a 44 s break:
```json
{"status":"running","startTimestamp":1791911608634,"workTimeElapsedSeconds":149,"breakElapsedSeconds":44,"accumulatedBreakSeconds":44,"isBusinessTripActive":false,"startOnlyOnTerminal":false,"pauseOnlyOnTerminal":false,"stopOnlyOnTerminal":false}
```
Work summary:
```json
{"commitmentMinutes":420,"workedMinutes":467,"remainingMinutes":0,"percentDone":100,"breakMinutes":90}
```
Profile (shape):
```json
{"id":"502572","name":"Max Mustermann","email":"max@example.com","role":"USER","department":"Entwicklung","avatar":"/images/avatar/x.jpg","isBusinessTripEnabled":false,"isTimeTrackingEnabled":true}
```

### 2.2 Verified semantics (important)

1. **Null fields are omitted**, not sent as `null` (`pauseTimestamp`, `waitSeconds`, `startTimestamp` when idle). Every nullable field must be an Optional, and decoding must tolerate missing keys. Unknown `status` values must decode to an `.unknown` case rather than failing.
2. `workTimeElapsedSeconds` is **net** work time (breaks excluded). It is computed **live at response time while `running`** and **frozen while `paused`**.
3. `breakElapsedSeconds` is the length of the current break while `paused`. **The docs are wrong here:** after resuming, it still holds the last break's length. **Only use it while `paused`.**
4. `accumulatedBreakSeconds` holds **completed** breaks only. It does **not** include the currently running break.
5. Identity (verified): `now − startTimestamp ≈ workTimeElapsedSeconds + accumulatedBreakSeconds + (paused ? breakElapsedSeconds : 0)`.
6. `/time-tracking/work-summary` covers **today's saved entries only**. It does **not** include the running session, so "today's total" = `summary.workedMinutes·60 + currentNetSeconds`.
7. Timestamps are Unix epoch **milliseconds**.
8. The API exposes no list of individual breaks. The detail view shows totals and the current break only.
9. With an invalid or malformed token, the server may return an **HTML** error page instead of JSON. Never show response bodies raw. Map by status code (§4.3), and if a 2xx response body fails to decode as JSON, report a generic "Unerwartete Antwort vom Server".

### 2.3 Stop flow (`POST /time-clock/stop`)

- First call: no body.
- `200` + `outcome == "saved"`: the shift is saved. Show a transient confirmation such as "Gespeichert: 7:32 h Arbeit, 0:45 h Pause", built from `workedMinutes` and `breakMinutes`. Then refresh status.
- `200` + `outcome == "confirmationRequired"`: nothing was saved yet. The shift is **still active**. Show the break-regulation confirmation **inline in the panel**:
  - `breakRegulation.detailText` (plain text; strip any HTML tags defensively)
  - "Ergebnis: H:MM Arbeit, H:MM Pause", from `resultingWorkMinutes` and `resultingBreakMinutes`
  - Buttons:
    - "Korrektur übernehmen" re-sends stop with body `{"breakRegulation":"apply"}` and `Content-Type: application/json`.
    - "Unverändert speichern" re-sends with `"ignore"`. Hide this button when `obligatory == true`.
    - "Zurück" sends nothing, and the shift keeps running.
  - If the re-send again returns `confirmationRequired`, show it again.
- `204`: the clock was in `waiting` and was discarded without saving. Show "Schicht verworfen (Mindestintervall nicht erreicht)".
- `409` from stop: it can mean shorter than 1 minute, a duplicate, or not active. Refresh status and show "Ausstempeln nicht möglich: Schicht zu kurz (unter 1 Minute) oder bereits beendet.".

`TimeClockStopResponse` fields:
- `outcome`: `saved` | `confirmationRequired`
- `id`: String?
- `workedMinutes`: Int?
- `breakMinutes`: Int?
- `breakRegulationApplied`: Bool?
- `breakRegulationIgnored`: Bool?
- `breakRegulation`: `TimeClockBreakRegulationInfo`? with fields:
  - `hasNoRemedy`, `obligatory`: Bool?
  - `correctionWorkMinutes`, `correctionBreakMinutes`, `resultingWorkMinutes`, `resultingBreakMinutes`: Int?
  - `detailText`: String?

Make every field optional except `outcome`, and give `outcome` an unknown fallback too.

## 3. Architecture

```
project.yml
TimebutlerToolbar/
  App/TimebutlerToolbarApp.swift      @main; MenuBarExtra(.window) + Window("Einstellungen", id: "settings")
  App/Info.plist                       generated via project.yml info: LSUIElement, CFBundleDisplayName "Timebutler"
  App/TimebutlerToolbar.entitlements   app-sandbox + network.client
  API/TimebutlerClient.swift           protocol TimeClockAPI + URLSession implementation (Sendable)
  API/Models.swift                     Codable DTOs (§2)
  API/APIError.swift                   error enum + German messages
  Storage/KeychainStore.swift          token CRUD (Security framework, generic password)
  Model/ShiftSnapshot.swift            pure value type: DTO + fetchedAt → computed durations at `now`
  Model/ShiftStore.swift               @MainActor @Observable app state, polling, actions
  Services/BreakReminder.swift         ArbZG notifications (UNUserNotificationCenter)
  Services/LaunchAtLogin.swift         SMAppService.mainApp wrapper
  UI/MenuBarLabel.swift
  UI/ShiftPanel.swift                  popover content (+ small subviews)
  UI/SettingsView.swift
  Support/DurationFormatting.swift
  Resources/Assets.xcassets            AppIcon may be empty
TimebutlerToolbarTests/                Swift Testing (`import Testing`)
scripts/install.sh                     Release build → copy to ~/Applications, relaunch
README.md
.gitignore
```

### 3.1 project.yml essentials
- `name: TimebutlerToolbar`, `options.deploymentTarget.macOS: "15.0"`, `bundleIdPrefix: de.lochimbaum`.
- App target `TimebutlerToolbar`, type `application`, platform `macOS`. Settings:
  - `PRODUCT_BUNDLE_IDENTIFIER=de.lochimbaum.TimebutlerToolbar`
  - `DEVELOPMENT_TEAM=<TEAM_ID>`, `CODE_SIGN_STYLE=Automatic`
  - `SWIFT_VERSION=6.0`, `SWIFT_STRICT_CONCURRENCY=complete`
  - `ENABLE_HARDENED_RUNTIME=YES`
  - `MARKETING_VERSION=1.0.0`, `CURRENT_PROJECT_VERSION=1`
  - `INFOPLIST_KEY_LSUIElement=YES` (or `info.properties`)
  - `GENERATE_INFOPLIST_FILE` or an explicit plist, whichever is cleaner with XcodeGen.
- Entitlements: `com.apple.security.app-sandbox = true`, `com.apple.security.network.client = true`.
- Test target `TimebutlerToolbarTests` (`bundle.unit-test`) hosted by the app. Make sure `xcodebuild test` works.
- Scheme `TimebutlerToolbar` with build + test.

### 3.2 Keychain (`KeychainStore`)
- Generic password with `kSecAttrService = "de.lochimbaum.TimebutlerToolbar"`, `kSecAttrAccount = "personal-access-token"`, `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecAttrSynchronizable = false`.
- API: `func readToken() throws -> String?`, `func saveToken(_:) throws` (update-or-add), `func deleteToken() throws`. Map `OSStatus` into a `KeychainError` with `SecCopyErrorMessageString`.
- The token is kept in memory in the store or client only. It never goes into `print`, `Logger`, or `UserDefaults`.
- Use a protocol (`TokenStore`) so tests can inject an in-memory store.

### 3.3 API client
- `protocol TimeClockAPI: Sendable` with async throwing methods: `status()`, `start()`, `pause()`, `resume()`, `stop(breakRegulation: BreakRegulation?) -> StopResult`, `cancel()`, `profile()`, `workSummary()`.
  - `StopResult`: `.saved(worked:break:)`, `.confirmationRequired(info)`, or `.discardedWhileWaiting`.
- Implementation: `URLSession` with a 15 s timeout and `waitsForConnectivity = false`. The token is passed in at init, or via a closure that reads it.
- `JSONDecoder` with no key strategy. Field names are camelCase already.
- Use `os.Logger` (subsystem = bundle id) only for method, path, status code and duration. **Never** log headers or the token.

### 3.4 Errors (`APIError`) and German messages
| Case | Trigger | Message |
|---|---|---|
| `.noToken` | no token stored | "Kein API-Token hinterlegt." |
| `.unauthorized` | 401, or an HTML response to an authed request with 4xx | "API-Token ungültig oder widerrufen." Panel offers "Einstellungen öffnen". |
| `.terminalOnly` | 403 | "Diese Aktion ist nur am Zeiterfassungsterminal erlaubt." |
| `.conflict` | 409 | Action-specific, e.g. "Die Stempeluhr läuft bereits." / "Die Stempeluhr ist nicht pausiert." / see §2.3. Always refresh status afterwards. |
| `.notEnabled` | 400 | "Zeiterfassung bzw. Stempeluhr ist für dein Konto nicht aktiviert." |
| `.server(code)` | 5xx | "Timebutler-Server-Fehler (code). Bitte später erneut versuchen." |
| `.network(URLError)` | transport error | "Keine Verbindung zu Timebutler." |
| `.decoding` | bad 2xx body | "Unerwartete Antwort vom Server." |

Use the informal "du" form consistently.

### 3.5 Time computation (`ShiftSnapshot`), pure and unit-tested
Store the decoded DTO plus `fetchedAt: Date`, the local time at which the response arrived. All live values are computed with a **monotonic delta** from `fetchedAt`, never from `now − startTimestamp`. That makes them immune to clock skew between the Mac and the server. Let `d = max(0, now − fetchedAt)`:
- `netWork(now)`: `running` → `work + d`; `paused` and `waiting` → `work`, frozen; `idle` → 0.
- `currentBreak(now)`: `paused` → `breakElapsed + d`; otherwise **0** (§2.2.3).
- `totalBreak(now)` = `accumulatedBreak + currentBreak(now)`.
- `gross(now)` = `netWork + totalBreak`.
- `shiftStart` = `startTimestamp` converted to `Date`. `breakStart` = `pauseTimestamp` converted to `Date`, when paused.

Guard against long gaps. If `d` exceeds 10 minutes, for example after sleep, the store must refetch before trusting values. The UI may keep ticking meanwhile.

`DurationFormatting`:
- `hmm(seconds)` → `"3:42"`. Hours aren't capped, so a long shift gives e.g. `"10:05"`. Use floor rounding.
- `hmmss(seconds)` → `"3:42:07"`.
- `minutesHmm(minutes)` → `"7:32"`.
- Clock times use `Date.FormatStyle` `HH:mm` in the user's locale and time zone.

### 3.6 `ShiftStore` (@MainActor @Observable)
State:
- `snapshot: ShiftSnapshot?`
- `profileName: String?`
- `workSummary: WorkSummaryResponse?`
- `isBusy` (an action is in flight; disables buttons and shows a spinner)
- `lastError: APIError?`
- `transientMessage: String?` (auto-clears after 6 s)
- `pendingConfirmation: BreakRegulationInfo?`
- `lastRefresh: Date?`
- `hasToken: Bool`
- `now: Date`

Behaviour:
- **Ticker:**
  - A `Timer`, or a `Task` loop with `Task.sleep(for: .seconds(1))`, updates `now` every second while the panel is open.
  - While the panel is closed, only update when the **label string would change**. Compute the next instant at which `hmm(netWork)` changes and sleep until then, capped at 60 s.
  - Assign `menuBarText` only when it actually changed, to avoid needless redraws.
- **Polling:** refresh `status` every 60 s, plus on the triggers below. Refresh `workSummary` on launch, after `stop` or `cancel`, on panel open, and every 10 min.
  - Triggers: app launch, panel open, `NSWorkspace.didWakeNotification`, token change, and 5 s after any 409 or network error, with exponential backoff up to 60 s.
  - Coalesce: never run two status requests concurrently.
- **Actions:** `clockIn()`, `startBreak()`, `endBreak()`, `clockOut()`, `confirmClockOut(apply: Bool)`, `cancelShift()`.
  - Each action sets `isBusy`, calls the API, and on success replaces `snapshot` with the response DTO (`fetchedAt = now`).
  - After `stop` or `cancel`, refresh the status and the work summary.
  - On error, set `lastError` and refresh the status. The state may have been changed elsewhere, e.g. in the web UI.
- **Profile:** fetch it on token save and on launch, for "Angemeldet als …".
- **Break reminders:** after every snapshot change, call `BreakReminder.update(with: snapshot)`.

### 3.7 Menu bar label
`MenuBarExtra { ShiftPanel() } label: { MenuBarLabel() }` with `.menuBarExtraStyle(.window)`. The label is an `HStack` or `Label` with an SF Symbol and `Text(menuBarText).monospacedDigit()`.

| State | Symbol | Text |
|---|---|---|
| no token / unauthorized | `clock.badge.exclamationmark` | none |
| idle | `clock` | none |
| running | `clock.fill` | `H:MM` net |
| paused | `pause.circle.fill` | `H:MM` net (frozen) |
| waiting | `hourglass` | `H:MM` net |
| unknown or no data yet | `clock` | none |

On a transient network error, keep showing the last known value and keep it ticking. Do not flicker. Verify that the label actually updates while the panel is closed; SwiftUI `MenuBarExtra` labels can be finicky. If it doesn't update reliably, fall back to an `NSStatusItem`-based implementation hosting the same SwiftUI panel in an `NSPopover` or `NSPanel`, and document why.

### 3.8 Detail panel (`ShiftPanel`), about 300 pt wide, native look
Top to bottom:
1. **Header:** status pill ("Nicht eingestempelt" / "Arbeitet" / "In Pause" / "Wartet" / "Unbekannt") and "Angemeldet als <Name>" in secondary text.
2. **Big net time** `H:MM:SS`, `.monospacedDigit()`, with the caption "Arbeitszeit (netto)". Hidden when idle; show "Noch nicht eingestempelt." instead.
3. **Detail rows** (Grid or Form-like, label left, value right). Only shown when not idle:
   - Beginn: `HH:mm`
   - Brutto (seit Beginn): `H:MM`
   - Pausen gesamt: `H:MM`
   - In Pause seit: `HH:mm (M:SS)`, only while paused
   - Wartezeit: `waitSeconds` countdown, only if present and > 0
4. **Today section** "Heute":
   - Gearbeitet: `H:MM` (summary + current net)
   - Soll: `H:MM`
   - Rest: `H:MM`, or "Überstunden: H:MM" when the total exceeds the target
   - A thin `ProgressView(value:)` showing the total against the target
   - Pausen heute: summary.breakMinutes + current totalBreak
5. **Action buttons** (large, full width, `.controlSize(.large)`):

   | State | Primary (`.borderedProminent`) | Secondary | Destructive (`.bordered`, red tint) |
   |---|---|---|---|
   | idle | "Einstempeln" | – | – |
   | running | "Pause starten" | "Ausstempeln" | "Abbrechen" |
   | paused | "Pause beenden" | "Ausstempeln" | "Abbrechen" |
   | waiting | – | "Ausstempeln" | "Abbrechen" |

   - Respect `startOnlyOnTerminal`, `pauseOnlyOnTerminal` and `stopOnlyOnTerminal`: disable the matching button with the help text "Nur am Terminal möglich".
   - "Abbrechen" is not covered by those flags. Leave it enabled and let a 403 surface as an error.
6. **Inline confirmations** in the panel itself. Do not use `.alert` or `.confirmationDialog`, which behave badly inside a MenuBarExtra window.
   - Ausstempeln: "Schicht jetzt beenden und speichern?" with [Ausstempeln] [Zurück]
   - Abbrechen: "Schicht verwerfen? Die erfasste Zeit (H:MM) wird **nicht** gespeichert." with [Verwerfen] (destructive) [Zurück]
   - Break regulation confirmation per §2.3
7. **Messages:** an error banner (`lastError`, with a "Erneut versuchen" button, plus "Einstellungen öffnen" for token errors) and a success banner (`transientMessage`).
8. **Footer** in small secondary text:
   - "Aktualisiert HH:mm:ss"
   - Refresh button (`arrow.clockwise`)
   - "Timebutler öffnen", which opens `https://app.timebutler.com` via `NSWorkspace`
   - "Einstellungen…"
   - "Beenden" (`NSApp.terminate`)

Opening settings: `openWindow(id: "settings")` followed by `NSApp.activate()`, so the window comes to the front in this LSUIElement app.

When there is no token, the panel shows a short onboarding text ("Hinterlege dein persönliches API-Token, um loszulegen.") with buttons "Einstellungen öffnen" and "Token in Timebutler erstellen". The second opens `https://app.timebutler.com/do?ha=personaltoken&ac=1`.

On first launch without a token, open the settings window automatically.

### 3.9 Settings window (`SettingsView`, `Form` with `.formStyle(.grouped)`, about 460 pt wide)
- **Section "Timebutler-Zugang":**
  - `SecureField("API-Token", …)`, placeholder `tb_…`
  - Button "Prüfen & speichern": trims the token, calls `GET /user/profile` with the **candidate** token, and saves it to the Keychain only on 200. Then shows "✓ Verbunden als <Name>". On 401 it shows "Token ungültig." and does not save.
    - If `isTimeTrackingEnabled == false`, warn: "Zeiterfassung ist für dein Konto nicht aktiviert."
  - With a token stored: show the status "Token gespeichert (tb_••••<last 4>)" and a "Token entfernen" button. Removing deletes it from the Keychain and resets the state.
  - Link "Persönliches Token in Timebutler erstellen…"
  - Footnote: "Das Token wird sicher im macOS-Schlüsselbund gespeichert."
- **Section "Allgemein":**
  - Toggle "Bei Anmeldung starten" (SMAppService.mainApp). Reflect the real `status`. Show an error inline if registration fails. If the status is `.requiresApproval`, show a hint with a button that opens the Login Items settings (`SMAppService.openSystemSettingsLoginItems()`).
  - Toggle "Pausenerinnerung (ArbZG)", default **on**. Explanation text: "Erinnert dich 15 Minuten bevor du 6 h bzw. 9 h Arbeitszeit erreichst, falls bis dahin noch nicht genug Pause (30 bzw. 45 Min.) erfasst ist."
- **Section "Info":** version string.

### 3.10 Break reminder (`BreakReminder`)
- Rules (ArbZG §4):

  | Threshold T (net) | Required break B |
  |---|---|
  | 6 h | 30 min |
  | 9 h | 45 min |

  Lead time: 15 min.
- On every snapshot update, remove the pending requests with identifiers `break-6h` and `break-9h`. Then, if the reminder is enabled, the state is `running`, and `totalBreak < B`, schedule a `UNTimeIntervalNotificationTrigger` at `fireIn = (T − 15 min) − netWork(now)`.
  - Only schedule if `fireIn > 0`.
  - If the lead point has already passed but `T` hasn't, and no reminder was delivered for this shift and threshold yet, fire immediately (`fireIn = 1`).
- Scheduling with a trigger means it fires on time even if the app is throttled.
- Do not schedule while paused. The next resume reschedules with the correct remaining time.
- Remember delivered reminders per shift in `UserDefaults` (key based on `startTimestamp` plus the threshold), so that relaunches don't duplicate them.
- Content:
  - Title "Pause nicht vergessen"
  - Body "In 15 Minuten erreichst du 6 Stunden Arbeitszeit. Bisher erfasst: X Min. Pause – nötig sind 30 Min."
- Request notification authorization (`.alert`, `.sound`) when the toggle is first enabled, or the first time a reminder would be scheduled. If denied, show a hint in Settings.
- **Unit-test the scheduling math** as a pure function: `(snapshot, now, enabled, delivered) -> [ScheduledReminder]`.

### 3.11 Launch at login
`SMAppService.mainApp.register()` / `unregister()`. Document in the README that this only works properly when the app is run from `~/Applications` or `/Applications`, which is what `scripts/install.sh` does.

## 4. Quality bar
- Swift 6 strict concurrency with **zero warnings**. No force-unwraps outside tests. No third-party dependencies.
- The views are thin. Logic lives in `ShiftStore`, `ShiftSnapshot` and `BreakReminder`, which are testable with a `MockTimeClockAPI` and an in-memory `TokenStore`.
- Tests (Swift Testing) must cover at least:
  - decoding of all samples in §2.1, including omitted optionals and an unknown status
  - `ShiftSnapshot` math for running, paused, after-resume (stale `breakElapsedSeconds` = 44 must be ignored), idle and waiting
  - formatting
  - status-code → `APIError` mapping, including an HTML body with 401 and 403
  - the stop flow (saved / confirmationRequired → apply / 204)
  - reminder scheduling math
  - store actions against the mock API, including a 409 triggering a refresh
- `xcodegen generate && xcodebuild -project TimebutlerToolbar.xcodeproj -scheme TimebutlerToolbar -destination 'platform=macOS' -allowProvisioningUpdates build test` must succeed.
- Accessibility: buttons have labels; the menu bar item has an accessibility label like "Timebutler: arbeitet, 3 Stunden 42 Minuten".
- Supports light/dark mode automatically, using system colors only.

## 5. Safety rules for the implementer
- **Never call the real Timebutler API** during development or tests. There is no token available to you, and the POST endpoints change real time-tracking data of the user. All tests use the mock.
- Do not touch the user's Keychain from tests.
- Do not commit with git unless asked. Running `git init` and creating `.gitignore` is fine.

## 6. Deliverables
1. All sources, `project.yml`, tests, `.gitignore` (ignoring `*.xcodeproj`, `build/`, `DerivedData/`, `.DS_Store`)
2. `scripts/install.sh`:
   - generate
   - Release build into `build/`, with `-allowProvisioningUpdates`
   - copy `TimebutlerToolbar.app` to `~/Applications/`
   - quit any running instance (`pkill -x TimebutlerToolbar || true`)
   - `open` the installed app
3. `README.md` in German: what it does, requirements, setup (`brew install xcodegen`, `scripts/install.sh`), how to create and enter the token, and known limitations: no individual breaks are listed; project and category aren't supported at clock-out.
4. A final report listing the files, build and test results, deviations from this plan with reasons, and anything that needs manual verification by the user.
