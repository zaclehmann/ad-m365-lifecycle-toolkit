# Design and plan

This document is the plan the toolkit was built from. It explains what the toolkit does and why each decision was made, so you can talk through it in an interview.

## 1. Problem

Joiners and leavers are the most repeated tasks on a helpdesk or sysadmin desk. Doing them by hand in ADUC, the M365 admin centre and Exchange admin is slow, and people make mistakes: a missed group, a leaver whose mailbox is deleted instead of kept, or a licence left on a disabled account. The toolkit turns both processes into a repeatable, logged and previewable script run driven by a CSV (the kind HR can export).

## 2. Assumed environment

| Component | Assumption |
|-----------|------------|
| Identity | On-prem Active Directory, synced to Entra ID by Entra Connect (hybrid identity). Users are created on-prem, never in the cloud. |
| Mail | Mailboxes live in Exchange Online. |
| Licensing | Group-based licensing (recommended) **or** direct assignment through Microsoft Graph. |
| Home drives | One SMB share, with one folder per user (`\\FS01\Home$\jsmith`). |
| Run host | A Windows admin box or jump server with RSAT AD tools, `Microsoft.Graph` and `ExchangeOnlineManagement`. Windows PowerShell 5.1 or PowerShell 7. |

The tooling is current: MSOnline and AzureAD modules are retired, so licensing uses the Microsoft Graph PowerShell SDK, and mail uses the EXO V3 module.

## 3. Requirements

**Onboarding (per CSV row)**
1. Validate the row (required fields, duplicate EmployeeIDs, a known department).
2. Generate a unique, sanitised `sAMAccountName` and UPN (for example `José O'Brien` becomes `jose.obrien`, then `jose.obrien2` if taken).
3. Create the AD user in the department OU, with a random complex password and "must change at next logon".
4. Add baseline, department and per-row groups.
5. Create the home folder, grant the user Modify by **SID**, and set `HomeDirectory`/`HomeDrive`.
6. Licence: add to the licence group (Group mode), or trigger a delta sync, wait for the cloud object, set `usageLocation` and assign the SKU (Direct mode).

**Offboarding (per CSV row or single user)**
1. Snapshot the user (attributes and groups) to JSON, so the leaver can be restored or audited.
2. Reset the password to a random value, disable the account, stamp the description, and hide it from the GAL.
3. Revoke all Entra sign-in sessions.
4. Convert the mailbox to shared, give the manager (or a named delegate) Full Access, and set an auto-reply.
5. Remove all group memberships, except protected groups.
6. Remove directly assigned licences, unless the mailbox is over 50 GB or on hold.
7. Optionally archive the home folder.
8. Move the account to the Disabled Users OU.

**Scheduled leavers.** A future `LeaveDate` only sets `AccountExpirationDate` to the day after it, and the leaver is reported as `Scheduled`. That's a safety net: access stops on time even if nobody runs the script on the day. The leavers CSV is meant to be run daily, and full offboarding happens on the first run on or after the leave date.

**Restore.** `Invoke-UserRestore.ps1` reverses an offboarding from the snapshot: original OU, groups, description, GAL visibility, a new password, the account re-enabled, direct licences, and the mailbox back to a user mailbox. It uses the user's *earliest* snapshot, because a re-run of offboarding snapshots an already-stripped account.

**Cross-cutting**
- `-WhatIf` on both scripts. It previews every change and still runs every read-only check, so it doubles as a pre-flight test.
- `-Confirm` support.
- One config file (`.psd1`) for all environment-specific values. The scripts contain no hard-coded OUs, groups or SKUs.
- Clear logs: coloured console output, a timestamped log file per run and a CSV results report per run.
- Idempotent: re-running the same CSV is safe and finishes anything a previous run left incomplete.

## 4. Key design decisions

| Decision | Why |
|----------|-----|
| **Config is a `.psd1`, not JSON** | `Import-PowerShellDataFile` only allows literals, so it can't run code, and it supports comments to document each setting. |
| **Script module plus two thin entry scripts** | Each logical step is its own function that can be tested on its own. The scripts read like the runbook. |
| **EmployeeID is the idempotency key** | Names collide and change, but the HR ID doesn't. If a starter with that ID exists, the user isn't created again; the remaining steps are *ensured* (missing groups added, missing folder created, missing licence assigned). |
| **Every change goes through one `ShouldProcess` wrapper (`Invoke-LtChange`)** | Gives one place that respects `-WhatIf`/`-Confirm` and logs `SUCCESS` or `WHATIF` the same way every time. |
| **`-WhatIf` is forwarded explicitly to module functions** | Preference variables don't reliably cross script-module boundaries. The entry scripts splat `WhatIf`/`Confirm` into every module call, and the module passes `-Confirm:$false` to inner AD cmdlets so a confirmed step doesn't prompt twice. |
| **Log writes use `[IO.File]::AppendAllText`** | `Add-Content` honours `-WhatIf`, so logs would silently stop in preview mode. |
| **Home folder ACL is granted by SID** | A brand-new account might not have replicated to the DC the file server asks yet. Name lookup fails there, but a SID doesn't need a lookup. |
| **Names reserved in memory during a run** | Under `-WhatIf` nothing is created, so two `John Smith` rows would both be shown as `john.smith`. Reserving names keeps the preview accurate. |
| **Passwords are never written to the log or report** | They're shown once on the console at the end of the run, and returned in `-PassThru` objects as a `SecureString` for automation. |
| **Each user gets their own try/catch** | One bad row doesn't stop a 50-row batch. The exit code is non-zero if any user failed. |

## 5. Offboarding order matters

```
Snapshot → Disable + reset pw → Revoke sessions → Mailbox to shared → Strip groups → Remove licences → Home folder → Move OU
```

- **Lock the account first.** Disabling and resetting the password doesn't touch the mailbox, so it can safely happen before anything else. Security comes first, and the leaver is locked out even if a later step fails.
- **Revoke sessions straight away.** Disabling in AD only reaches Entra on the next sync (up to 30 minutes), but revoking refresh tokens cuts access now. A delta sync is also triggered at the end of the run.
- **Mailbox before licences/groups.** If the licence is removed first (directly, or by removing the licence group), the mailbox starts the 30-day deletion countdown. Converting to shared first keeps the data. **If conversion fails, group and licence removal are skipped** and the leaver is reported as `Partial`, so re-running after the fix finishes the job.
- **Snapshot before groups are stripped**, so it can be restored.
- **Licence check.** A shared mailbox over 50 GB, or on litigation hold, still needs a licence, so licence removal is skipped with a warning.
- **Move OU last.** Moving changes the DN, so all other AD changes use the object GUID, and the move goes at the end.

## 6. Exit codes and statuses

| Status | Meaning |
|--------|---------|
| `Success` | Every step completed (or was already in place). |
| `Partial` | The account exists or was disabled, but a later step failed (for example a licence timeout). Re-run to finish. |
| `Failed` | The row was invalid or the core step failed. |
| `WhatIf` | Preview only, nothing changed. |

Exit codes: `0` all OK, `1` at least one Partial or Failed, `2` config or CSV could not be loaded.

## 7. Layout

```
Invoke-Onboarding.ps1          entry script (CSV -> joiners)
Invoke-Offboarding.ps1         entry script (CSV or -Identity -> leavers)
Invoke-UserRestore.ps1         entry script (snapshot -> restored user)
config/toolkit.config.psd1     all environment settings
samples/*.csv                  example input files
src/LifecycleToolkit/          module (Private = helpers, Public = steps)
tests/                         Pester tests + in-memory fake AD/Graph/EXO
```

## 8. Testing strategy

- **Unit tests (Pester 5)** cover name generation, password complexity, template expansion, config and CSV validation.
- **Integration tests** run both entry scripts end to end against `tests/Fakes/FakeEnvironment.ps1`. That file is an in-memory stand-in for the AD, Graph and EXO cmdlets, so the tests run on Linux CI with no domain. They check that `-WhatIf` changes nothing, that a re-run is idempotent, and that offboarding happens in the right order.
- **PSScriptAnalyzer** runs in CI.

## 9. Static analysis

PSScriptAnalyzer runs in CI and fails the build on any warning. The rules that are suppressed, and why:

- `PSAvoidUsingWriteHost` (all files): coloured operator output is the point of `Write-LtLog`.
- `PSShouldProcess` (ActiveDirectory.ps1, Cloud.ps1, Invoke-LtChange): the functions *do* call `ShouldProcess`, via `Invoke-LtChange -Cmdlet $PSCmdlet`, but the analyzer only looks for a literal call in the same function.

Passwords are built directly into a `SecureString` (never `ConvertTo-SecureString -AsPlainText`), and are only turned back into text once, for the console.

## 10. Out of scope / future ideas

- Pulling starters straight from an HR system API instead of CSV.
- Delivering passwords to the manager by email or a password manager.
- On-prem Exchange (`Set-RemoteMailbox -Type Shared`) for hybrid Exchange shops.
- Teams/OneDrive handover (OneDrive access for the manager).
