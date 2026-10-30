# AD / M365 user onboarding and offboarding toolkit (PowerShell)

[![CI](https://github.com/zaclehmann/AD-M365-user-onboarding-and-offboarding-toolkit-PowerShell-/actions/workflows/ci.yml/badge.svg)](https://github.com/zaclehmann/AD-M365-user-onboarding-and-offboarding-toolkit-PowerShell-/actions/workflows/ci.yml)
![PowerShell 5.1 | 7](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE?logo=powershell&logoColor=white)

Automates joiners and leavers for a **hybrid** environment: on-prem Active Directory synced to Entra ID, with mailboxes in Exchange Online.

- **Onboarding** reads new starters from a CSV. For each one it creates the AD user in the right OU, adds groups, creates the home folder and assigns the Microsoft 365 licence.
- **Offboarding** saves a snapshot of the user, disables the account, revokes sessions, converts the mailbox to shared (with manager access and an auto-reply), strips groups, removes licences and moves the account to a Disabled OU. Leavers with a future leave date are scheduled instead.
- **Restore** puts an offboarded user back exactly as they were, using that snapshot.
- All three scripts support **`-WhatIf`** and **`-Confirm`**, read every environment-specific value from **one config file**, and write a **timestamped log file and a CSV report** for every run.

```
PS> .\Invoke-Onboarding.ps1 -CsvPath .\samples\new-starters.csv -WhatIf

2026-11-03 08:30:01.112 [INFO   ] Onboarding run 7a3dc66c started by CONTOSO\zac on ADMIN01 [WHATIF - no changes will be made]
2026-11-03 08:30:01.140 [INFO   ] Loaded 3 starter(s) from CSV
2026-11-03 08:30:01.402 [WHATIF ] [jane.smith2] Would: Create AD user -> CN=Jane Smith,OU=Finance,OU=Users,OU=Contoso,DC=contoso,DC=local
2026-11-03 08:30:01.441 [WHATIF ] [jane.smith2] Would: Add to group -> GG_AllStaff
2026-11-03 08:30:01.452 [WHATIF ] [jane.smith2] Would: Add to group -> GG_Finance
2026-11-03 08:30:01.470 [WHATIF ] [jane.smith2] Would: Add to group -> LIC_M365_E3
2026-11-03 08:30:01.476 [WHATIF ] [jane.smith2] Would: Create home folder -> \\FS01\Home$\jane.smith2
...
2026-11-03 08:30:02.088 [SUCCESS] Finished. 3 starter(s): WhatIf=3
```

## Features

| | |
|---|---|
| **Safe preview** | `-WhatIf` changes nothing but still runs every read-only check: OUs, groups, manager accounts, licence SKUs and free licence counts. It works as a pre-flight test. |
| **Idempotent** | EmployeeID is the key. Re-running a CSV never creates duplicates; it finishes whatever was left (missing groups, home folder, licence). |
| **Sensible usernames** | `José O'Brien` becomes `jose.obrien`. A clash becomes `jose.obrien2`. Names are kept within the 20-character sAMAccountName limit. |
| **Safe offboarding order** | The mailbox is converted to shared *before* any group or licence is removed, so mail is never lost. If conversion fails, those steps are skipped. |
| **Scheduled leavers** | A future `LeaveDate` sets the account to expire at the end of that day, as a safety net. The leaver is fully offboarded on the first run on or after that date. |
| **Undo** | `Invoke-UserRestore.ps1` restores OU, groups, description, licences and the mailbox from the leaver's snapshot. |
| **Licence-aware** | Group-based licensing or direct Graph assignment. Leavers keep their licence when the shared mailbox is over 50 GB or on hold. |
| **Audit trail** | Per-run log file and CSV report, a JSON snapshot of every leaver's groups, and an AD description such as `Leaver 2026-11-03 - INC0042117 - by zac`. |
| **No secrets in logs** | Initial passwords are shown once on screen and never written to the log file or report. |
| **Tested without a domain** | Pester tests run the real scripts against an in-memory fake AD/Graph/EXO in CI. |

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on a domain-joined admin machine.
- **RSAT Active Directory** module: `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`
- For M365 steps:
  ```powershell
  Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Users.Actions, Microsoft.Graph.Identity.DirectoryManagement
  Install-Module ExchangeOnlineManagement
  ```
- Permissions:
  - AD: create/modify users in the target OUs, and manage the groups.
  - File share: create folders and change permissions under the home root.
  - Graph: `User.ReadWrite.All`, `Organization.Read.All`, `User.RevokeSessions.All`.
  - Exchange: Exchange Administrator (or Recipient Management).
  - Entra Connect: remote PowerShell to the sync server (for `Start-ADSyncSyncCycle`).

## Quick start

1. **Edit `config/toolkit.config.psd1`.** It holds your UPN suffix, OUs, groups, home share, tenant and licence settings. Every setting is commented.
2. **Fill in a CSV** using the files in `samples/` as templates.
3. **Preview:**
   ```powershell
   .\Invoke-Onboarding.ps1 -CsvPath .\starters.csv -WhatIf
   ```
4. **Run for real:**
   ```powershell
   .\Invoke-Onboarding.ps1 -CsvPath .\starters.csv
   ```
5. **Offboard** a CSV of leavers, or a single user:
   ```powershell
   .\Invoke-Offboarding.ps1 -CsvPath .\leavers.csv -WhatIf
   .\Invoke-Offboarding.ps1 -Identity tom.baker -Ticket INC0042117
   .\Invoke-Offboarding.ps1 -Identity amy.wong@contoso.com -Ticket INC0042118 -Delegate sara.khan
   .\Invoke-Offboarding.ps1 -Identity priya.patel -Ticket CHG0012001 -LeaveDate 2026-12-18
   ```
6. **Restore** a leaver who comes back, or one offboarded by mistake:
   ```powershell
   .\Invoke-UserRestore.ps1 -Identity tom.baker -Ticket INC0042200 -WhatIf
   ```

Not got a domain to hand? Run `./tests/Invoke-Demo.ps1` to see the full joiner and leaver flow against the fake directory.

## CSV formats

**Starters** (`samples/new-starters.csv`)

| Column | Required | Notes |
|---|---|---|
| FirstName, LastName | ✔ | Accents and apostrophes are handled. |
| EmployeeId | ✔ | HR ID, and the idempotency key. Must be unique. |
| Department | ✔ | Picks the OU and department groups from the config. |
| JobTitle, Office | | Copied to AD. |
| Manager | | sAMAccountName or UPN. |
| Groups | | Extra groups, separated by `;`. |
| UsageLocation | | 2-letter country code. Defaults to the config value. |
| LicenseSku | | Direct mode only, e.g. `SPE_E5`. Defaults to the config value. |

**Leavers** (`samples/leavers.csv`)

| Column | Required | Notes |
|---|---|---|
| Identity | ✔ | sAMAccountName or UPN. |
| Ticket | ✔ | Change or incident reference. Goes in the description and the log. |
| LeaveDate | | `yyyy-MM-dd`. If it's in the future, the leaver is scheduled rather than offboarded. |
| Delegate | | Who gets Full Access to the mailbox. Defaults to the manager. |
| AutoReplyMessage | | Overrides the template in the config. |

## What each script does

**Onboarding**, for each row:
1. Validates the row.
2. Creates the AD user (department OU, random 16-character password, change at next logon).
3. Adds baseline, department and CSV groups, plus the licence group in Group mode.
4. Creates the home folder, grants Modify by SID, and sets `HomeDirectory`/`HomeDrive`.
5. Direct mode only: one delta sync for the whole batch, then waits for each user in Entra ID, sets `usageLocation` and assigns the SKU.

**Offboarding**, for each leaver:
1. Saves a JSON snapshot of attributes and groups.
2. Resets the password, disables the account, sets the description and hides it from the GAL.
3. Revokes all sign-in sessions.
4. Converts the mailbox to shared, grants Full Access to the manager or delegate, and sets the auto-reply.
5. Removes groups (except protected ones like `Domain Users`).
6. Removes direct licences, unless the mailbox is over 50 GB or on hold.
7. Archives the home folder (optional).
8. Moves the account to the Disabled Users OU.
9. One delta sync at the end of the run.

A leaver whose `LeaveDate` is in the future only has their account expiry set, and is reported as `Scheduled`. Run the leavers CSV daily (e.g. from Task Scheduler) and each leaver is offboarded on their day.

**Restore**, from the earliest snapshot for the user (or one named with `-SnapshotPath`):
1. Moves the account back to its original OU.
2. Re-adds its groups.
3. Restores the description and GAL visibility, and clears the expiry.
4. Sets a new password (shown once) and enables the account.
5. Restores direct licences, converts the mailbox back to a user mailbox and turns off the auto-reply.

Delegates added at offboarding keep their mailbox access, and an archived home folder isn't moved back. Both are listed in the log as manual follow-ups.

`docs/DESIGN.md` explains *why* the steps are in this order, and the other design decisions.

## Output

| Path | Contents |
|---|---|
| `logs/<op>_<time>_<runid>.log` | Every action, with timestamp, level and user. Old logs are pruned after `Logging.RetentionDays`. |
| `output/reports/<op>_<time>_<runid>.csv` | One row per user: Status, Actions, Warnings, Errors. |
| `output/snapshots/<user>_<time>.json` | Leaver state before any change. |

Statuses are `Success`, `Partial` (re-run to finish), `Failed`, `Scheduled` and `WhatIf`.

Exit codes are `0` when all users succeeded (or were scheduled), `1` when any user failed or partly failed, and `2` when the config or CSV couldn't be loaded. That makes the scripts easy to run from Task Scheduler or a pipeline.

## Unattended runs

For scheduled runs, set `M365.ClientId` and `M365.CertificateThumbprint` in the config to use an Entra app registration with certificate auth. Give it the Graph application permissions above, plus the `Exchange.ManageAsApp` role. Leave them blank for interactive sign-in.

## Project layout

```
Invoke-Onboarding.ps1          entry script for joiners
Invoke-Offboarding.ps1         entry script for leavers
Invoke-UserRestore.ps1         undo an offboarding from its snapshot
config/toolkit.config.psd1     every environment-specific setting
samples/                       example CSVs
src/LifecycleToolkit/          PowerShell module: one function per step
  Private/                     ShouldProcess wrapper, helpers
  Public/                      Logging, Common, ActiveDirectory, Cloud
tests/                         Pester unit + integration tests, fake AD/M365, demo
docs/DESIGN.md                 design decisions and offboarding order rationale
```

## Tests

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Invoke-Pester ./tests
```

CI (GitHub Actions) runs PSScriptAnalyzer and the Pester suite on Ubuntu (PowerShell 7) and Windows (PowerShell 7 and Windows PowerShell 5.1).

The integration tests run the real scripts against `tests/Fakes/FakeEnvironment.ps1`, an in-memory stand-in for the AD, Graph and Exchange Online cmdlets. They check behaviour and ordering, but not real-service quirks. See [Limitations](#limitations).

## Limitations

- **Not yet run against a live domain or tenant.** Everything is tested against the fake environment. Try it in a lab (one DC, Entra Connect and an M365 developer tenant) before production, starting with `-WhatIf`.
- **Exchange Online only.** For mailboxes still on-prem in a hybrid Exchange setup, conversion needs `Set-RemoteMailbox` instead.
- **Hide from GAL** writes `msExchHideFromAddressLists` in AD, which needs the Exchange schema extensions. Set `HideFromGalOnLeave = $false` if you don't have them.
- **Not handled:** OneDrive/Teams handover for leavers, sending initial passwords to managers, and reading starters straight from an HR system.

See [CHANGELOG.md](CHANGELOG.md) for version history.
