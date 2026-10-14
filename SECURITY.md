# Security Policy

Timebutler Toolbar handles a personal Timebutler API token that grants access to your time-tracking data. Security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately via GitHub instead: open the repository's **Security** tab and choose **Report a vulnerability**.

Please include steps to reproduce and the affected version or commit. You can expect a first response within a few days.

## Scope

In scope: anything that could leak or misuse the stored token (Keychain handling, logging, network requests), and any way the app could act on a Timebutler account without the user's intent.

Out of scope: vulnerabilities in Timebutler itself. Please report those to Timebutler directly.

## Your token

- The token is stored only in the macOS Keychain (this device only, not synced via iCloud), and is never written to logs or `UserDefaults`.
- If you think your token was exposed, revoke it in Timebutler and create a new one.
