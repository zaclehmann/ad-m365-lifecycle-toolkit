# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## 1.1.0 - 2026-10-30

### Added
- `Invoke-UserRestore.ps1` restores an offboarded user from their snapshot: original OU, groups, description, GAL visibility, a new password, direct licences, and the mailbox back to a user mailbox.
- Scheduled leavers: an optional `LeaveDate` (CSV column or `-LeaveDate`). A future date sets the account to expire at the end of that day and reports the leaver as `Scheduled`.
- Snapshots now record direct licence SKUs and the mailbox type, so a restore can put them back.
- The demo script now covers scheduling and restore.
- CI badge, `.gitattributes`, this changelog, and an MIT No Attribution licence.

### Changed
- Initial passwords are built directly into a `SecureString`; there is no plain-text conversion.
- Snapshot file names include milliseconds, so two quick runs can't overwrite each other.
- PSScriptAnalyzer now fails CI on warnings as well as errors.
- `actions/checkout` updated to v5.

## 1.0.0 - 2026-10-30

### Added
- `Invoke-Onboarding.ps1`: AD user creation from CSV, groups, home folder, and M365 licensing (group-based or direct through Graph).
- `Invoke-Offboarding.ps1`: snapshot, disable, revoke sessions, shared-mailbox conversion, group and licence removal, home folder archive, move to the Disabled OU.
- `-WhatIf` and `-Confirm` on every change, a single `.psd1` config, and a per-run log and CSV report.
- Pester unit and integration tests against an in-memory fake AD, Graph and Exchange Online.
