# Downloads Auto‑Archiver

[![Downloads-Auto-Archiver Tests](https://github.com/aalex954/downloads-auto-archiver/actions/workflows/main.yml/badge.svg)](https://github.com/aalex954/downloads-auto-archiver/actions/workflows/main.yml)

Safely and efficiently moves **old or untouched items** from your Windows 11 **Downloads** folder to a **NAS / mapped drive** on a recurring schedule. Built for **Task Scheduler**. Defaults to **DRY‑RUN** so you can audit actions before anything is moved.

**Script file:** `Downloads-Auto-Archiver.ps1`

---

## Key features

* **Top‑level rules for files** (not inside folders):

  * Untouched (LastAccessTime) ≥ X
  * Age (CreationTime or LastWriteTime) ≥ X
  * Combine with **AND/OR**
* **Top‑level rules for folders** (treat folders as a unit):

  * Untouched (LastAccessTime) ≥ X
  * Age (CreationTime or LastWriteTime) ≥ X
  * Combine with **AND/OR**
  * **Deep folder activity scan** (optional, enabled by default here) checks descendants to avoid moving “active” folders
* **Archive extracted rule:** move archives (`.zip/.7z/.rar/.tar*` etc.) that have a **sibling folder** with the same stem
* **Ignore in‑progress downloads:** extended patterns for Chromium/Firefox/IDM/qBittorrent/NZB tools
* **Include/Exclude name patterns**
* **Conflict‑safe moves:** `RenameWithTimestamp` (default), or `Skip`/`Overwrite`
* **Year/Month bucketing** under the destination root (e.g., `Z:\Downloads_Archive\2025\08`)
* **Robust moves**: optional **robocopy /MOV** for large files (default for ≥ 256 MB)
* **Logging**: JSON Lines **and** CSV, to local and/or remote folders
* **Cleanup**: delete **empty** folders left behind
* **Safety caps**: max operations per run; free‑space check on destination
* **Optional configuration file**: Load parameters from a `.json` or `.psd1` config file, with command-line parameters taking precedence

> **Note on LastAccessTime (Untouched):** Windows may throttle/disable LastAccessTime updates. If it’s stale, rely more on `OlderThan` rules, or consider adjusting OS policy (see below).

---

## Requirements

* Windows 11
* PowerShell 5.1 or PowerShell 7+
* A reachable NAS destination (mapped drive letter **or** UNC path). For Scheduled Tasks running under service accounts, **prefer UNC**.

---

## Installation

1. Create a folder such as `C:\Scripts` and save `Downloads-Auto-Archiver.ps1` there.
2. Ensure the destination exists (e.g., `Z:\Downloads_Archive` or `\\NAS\share\Downloads_Archive`).
3. Optionally create log folders you plan to use (script will also create them on first run):

   * Local: `C:\ProgramData\DownloadsAutoArchiver\logs`
   * Remote: e.g., `Z:\Downloads_Archive\_logs`

---

## Configuration (parameters & config file)

You can configure the script in two ways:

### 1. Parameters

Adjust parameters at the top of the script or pass them on the command line.

| Parameter                      | Type / Values                                | Default                                     | Notes                                                                             |
| ------------------------------ | -------------------------------------------- | ------------------------------------------- | --------------------------------------------------------------------------------- |
| `SourceDir`                    | string                                       | `$env:USERPROFILE\Downloads`                | Top‑level scanned directory                                                       |
| `DestinationRoot`              | string                                       | `Z:\Downloads_Archive`                      | Prefer UNC for Scheduled Tasks (e.g., `\\NAS\share\Downloads_Archive`)            |
| `DryRun`                       | string                                       | **`$true`**                                 | **Audit first.** Set to `$false` to actually move items                           |
| `VerboseLog`                   | switch                                       | `$false`                                    | Console‑style messages in Task Scheduler history                                  |
| `LocalLogDir`                  | string                                       | `C:\ProgramData\DownloadsAutoArchiver\logs` | JSONL + CSV written here                                                          |
| `RemoteLogDir`                 | string or `$null`                            | `Z:\Downloads_Archive\_logs`                | Set `$null` to disable remote logging                                             |
| `ConfigFile`                   | string (optional)                            | `$null`                                     | **Path to a `.json` or `.psd1` config file** (see below)                          |
| `RequireConfirmation`          | string                                       | **`$true`**                                 | Interactive confirmation required before any destructive run when `-DryRun:$false`|
| `FileUntouchedOlderThan`       | `TimeSpan?`                                  | `14 days`                                   | Top‑level files: LastAccessTime threshold                                         |
| `FileOlderThan`                | `TimeSpan?`                                  | `30 days`                                   | Top‑level files: age using `FileAgeProperty`                                      |
| `FileTimeCombine`              | `AND`/`OR`                                   | `AND`                                       | How to combine untouched + age for files                                          |
| `FileAgeProperty`              | `CreationTime`/`LastWriteTime`               | `CreationTime`                              | Which property defines “age”                                                      |
| `FolderUntouchedOlderThan`     | `TimeSpan?`                                  | `30 days`                                   | Top‑level folders unit‑move logic                                                 |
| `FolderOlderThan`              | `TimeSpan?`                                  | `45 days`                                   | —                                                                                 |
| `FolderTimeCombine`            | `AND`/`OR`                                   | `AND`                                       | —                                                                                 |
| `FolderAgeProperty`            | `CreationTime`/`LastWriteTime`               | `CreationTime`                              | —                                                                                 |
| `DeepFolderActivityScan`       | switch                                       | **`$true`**                                 | Uses latest activity of **descendants** (slower, safer)                           |
| `ArchiveExtensions`            | string\[]                                    | common archive types                        | Add more if needed                                                                |
| `ArchiveExtractedGraceMinutes` | int                                          | `30`                                        | Don’t move very fresh archives immediately                                        |
| `IncludePatterns`              | string\[]                                    | `*`                                         | Only names matching any include pattern are eligible                              |
| `ExcludePatterns`              | string\[]                                    | see below                                   | Skips partial/in‑progress files                                                   |
| `IgnoreHidden`                 | switch                                       | `$true`                                     | Skip items with Hidden attribute                                                  |
| `OnNameConflict`               | `Skip`/`Overwrite`/**`RenameWithTimestamp`** | `RenameWithTimestamp`                       | Destination conflicts                                                             |
| `MaxOperationsPerRun`          | int                                          | `500`                                       | Safety cap                                                                        |
| `MinFreeSpaceMB`               | int                                          | `512`                                       | Abort if destination free space below this                                        |
| `UseRobocopy`                  | switch                                       | `$true`                                     | Better for large files / network hiccups                                          |
| `RobocopyLargeFileMB`          | int                                          | `256`                                       | Threshold for robocopy vs Move‑Item                                               |
| `DeleteEmptyFolders`           | switch                                       | `$true`                                     | Remove empty dirs post‑move                                                       |

**Current `ExcludePatterns` default** (expanded):

```
*.crdownload, *.opdownload, *.download, *.aria2, *.part, *.filepart, *.tmp, *.temp, *.!ut, *.!qB, _UNPACK_*, _FAILED_*
```

Add or remove patterns to match your tools.

### 2. Configuration file (NEW)

You can now specify a configuration file using the `-ConfigFile` parameter. Supported formats:

- **JSON** (`.json`)
- **PowerShell data file** (`.psd1`)

**Example usage:**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Downloads-Auto-Archiver.ps1" -ConfigFile "C:\Scripts\archiver-config.json"
```

**Example JSON config:**

```json
{
  "SourceDir": "C:\\Users\\user\\Downloads",
  "DestinationRoot": "Z:\\Downloads_Archive",
  "DryRun": false,
  "MaxOperationsPerRun": 100
}
```

**Example PSD1 config:**

```powershell
@{
    SourceDir = 'C:\Users\user\Downloads'
    DestinationRoot = 'Z:\Downloads_Archive'
    DryRun = $false
    MaxOperationsPerRun = 100
}
```

**Notes:**

- Any parameter set on the command line **overrides** the config file.
- If a parameter is not set on the command line, the config file value is used.
- If neither is set, the script's default is used.

---

## Usage

### 1) Dry‑run (audit only)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Downloads-Auto-Archiver.ps1" -DryRun -VerboseLog
```

### 2) Live run (actually move)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Downloads-Auto-Archiver.ps1" -DryRun:$false
```

### 3) Using a configuration file

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Downloads-Auto-Archiver.ps1" -ConfigFile "C:\Scripts\archiver-config.json"
```

You can still override any parameter on the command line:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Downloads-Auto-Archiver.ps1" -ConfigFile "C:\Scripts\archiver-config.json" -DryRun
```

### 4) Common policy examples

Move files untouched ≥ 10 days **OR** older than 20 days; folders require **AND** with deep scan; UNC dest:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Downloads-Auto-Archiver.ps1" `
  -DestinationRoot "\\NAS\Share\Downloads_Archive" `
  -FileUntouchedOlderThan (New-TimeSpan -Days 10) `
  -FileOlderThan (New-TimeSpan -Days 20) `
  -FileTimeCombine OR `
  -FolderUntouchedOlderThan (New-TimeSpan -Days 21) `
  -FolderOlderThan (New-TimeSpan -Days 30) `
  -FolderTimeCombine AND `
  -DeepFolderActivityScan `
  -DryRun:$false
```

Only archive‑extracted moves (top‑level) + skip conflicts:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Downloads-Auto-Archiver.ps1" `
  -FileUntouchedOlderThan $null -FileOlderThan $null `
  -FolderUntouchedOlderThan $null -FolderOlderThan $null `
  -OnNameConflict Skip -DryRun:$false
```

Include only certain types, exclude ISO and temp:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Downloads-Auto-Archiver.ps1" `
  -IncludePatterns '*.pdf','*.zip','*.msi' -ExcludePatterns '*.iso','*.tmp'
```

### 5) My policy
Audits top-level items in `%USERPROFILE%\Downloads` and moves matches to `A:\Downloads Auto-Archiver\YYYY\MM`, with local/remote logs, rename-on-conflict, Robocopy for `≥256` MB, a 500-operation safety cap, and empty-folder cleanup. Selection requires files untouched ≥14 days AND age ≥30 days, folders untouched ≥30 days AND age ≥45 days (deep descendant activity considered); extracted archives (archive + matching sibling folder) qualify after a 30-minute grace, while hidden and in-progress downloads are ignored.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Downloads Auto-Archiver.ps1" `
  -SourceDir "$env:USERPROFILE\Downloads" `
  -DestinationRoot "A:\Downloads Auto-Archiver" `
  -DryRun `
  -LocalLogDir "$env:USERPROFILE\Downloads\DownloadsAutoArchiver\logs" `
  -RemoteLogDir "A:\Downloads Auto-Archiver\_logs" `
  -FileUntouchedOlderThan (New-TimeSpan -Days 14) `
  -FileOlderThan (New-TimeSpan -Days 30) `
  -FileTimeCombine AND `
  -FileAgeProperty CreationTime `
  -FolderUntouchedOlderThan (New-TimeSpan -Days 30) `
  -FolderOlderThan (New-TimeSpan -Days 45) `
  -FolderTimeCombine AND `
  -FolderAgeProperty CreationTime `
  -DeepFolderActivityScan `
  -ArchiveExtensions '*.zip','*.7z','*.rar','*.tar','*.tar.gz','*.tgz','*.tar.bz2','*.tbz2','*.tar.xz','*.txz','*.iso' `
  -ArchiveExtractedGraceMinutes 30 `
  -IncludePatterns '*' `
  -ExcludePatterns '*.crdownload','*.opdownload','*.download','*.aria2','*.part','*.filepart','*.tmp','*.temp','*.!ut','*.!qB','_UNPACK_*','_FAILED_*' `
  -IgnoreHidden `
  -OnNameConflict RenameWithTimestamp `
  -MaxOperationsPerRun 500 `
  -MinFreeSpaceMB 512 `
  -UseRobocopy `
  -RobocopyLargeFileMB 256 `
  -DeleteEmptyFolders
```

---

## Scheduling (Task Scheduler)

### Quick (PowerShell)

```powershell
$script = 'C:\Scripts\Downloads-Auto-Archiver.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File '$script' -VerboseLog"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 60) -RepetitionDuration ([TimeSpan]::MaxValue)
Register-ScheduledTask -TaskName 'Downloads Auto-Archiver' -Action $action -Trigger $trigger -Description 'Moves old/untouched items from Downloads to NAS' -RunLevel Highest
```

### GUI steps

1. Open **Task Scheduler** → **Create Task…**
2. **General**: Name = *Downloads Auto‑Archiver*; check **Run whether user is logged on or not**; **Run with highest privileges**.
3. **Triggers**: New → *Daily* or *At log on* or *On a schedule* (e.g., every hour).
4. **Actions**: New → Program/script: `powershell.exe` → Arguments:

   ```
   -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Downloads-Auto-Archiver.ps1"
   ```
5. **Conditions**: Optional “Start the task only if the computer is idle/on AC power” as you prefer.
6. **Settings**: Allow task to run on demand; Stop the task if it runs longer than X; If the running task does not end when requested, force stop.

> **Mapped drives in Scheduled Tasks:** Drive letters may not exist in the task’s session. Prefer **UNC paths** in `DestinationRoot` and `RemoteLogDir`, or map drives within the task using a pre‑action script.

---

## Logging

* **Formats:** JSON Lines (`DownloadsAutoArchiver.log.jsonl`) and CSV (`DownloadsAutoArchiver.log.csv`).
* **Locations:** `LocalLogDir` and (optionally) `RemoteLogDir`.
* **JSONL example line:**

```json
{"ts":"2025-08-25T05:10:42","level":"INFO","message":"Moved [file-time]: C:\\Users\\you\\Downloads\\invoice.pdf -> \\NAS\\Share\\Downloads_Archive\\2025\\08\\invoice.pdf","path":"C:\\Users\\you\\Downloads\\invoice.pdf","dest":"\\\\NAS\\Share\\Downloads_Archive\\2025\\08\\invoice.pdf","reason":"file-time"}
```

* **Levels:** INFO, WARN, ERROR. Errors include exception text under `err`.

---

## How selection works

* **Top‑level files only** are evaluated by file rules. Files inside subfolders are **not** individually moved.
* **Top‑level folders** are treated as a **unit**. With `-DeepFolderActivityScan`, the script computes the most recent access/write of any descendant; if recent, the folder is **not** moved.
* **Archive extracted rule** applies only to **top‑level** archives that have a sibling directory named after the archive’s stem.

---

## Performance tips

* Keep `DeepFolderActivityScan` **on** for safety; turn it **off** if you have extremely large trees and need speed.
* `UseRobocopy` for large files is recommended (default); adjust `RobocopyLargeFileMB` if needed.
* Increase `MaxOperationsPerRun` gradually after confirming behavior in dry‑run.

---

## Troubleshooting

* **Destination not found / permission denied**: Verify `DestinationRoot` exists and that the task’s run‑as account can write to it. Prefer **UNC** paths.
* **LastAccessTime seems wrong**: Windows may not update this frequently. Check:

  ```
  fsutil behavior query DisableLastAccess
  ```

  Values `2` (system managed) or `0` (always update) are workable. Changing requires admin and reboot:

  ```
  fsutil behavior set DisableLastAccess 2
  ```
* **Robocopy exit codes**: Codes < 8 are success/non‑fatal; ≥ 8 indicates failure (script logs an ERROR).
* **Nothing moves**: You might still be in `-DryRun`; or your thresholds/patterns exclude matching items.
* **Mapped drive not visible to task**: Use UNC or map the drive within the task context.

---

## Security & safety

* The script defaults to **dry‑run**.
* Consider code‑signing or restricting execution policy to signed scripts in production.
* Logs contain **file names/paths**; route remote logs to a private share if sensitive.

---

## Uninstall / Disable

```powershell
Unregister-ScheduledTask -TaskName 'Downloads Auto-Archiver' -Confirm:$false
```

Delete the script and log folders if no longer needed.

---

## Changelog

**v1.2**

* Safety improvements and bug fixes:
  * Added `-ConfigFile` support (.json/.psd1) with correct precedence.
  * Validate `DestinationRoot` after loading config.
  * Create log/destination directories automatically if missing.
  * Fixed Test-TimeRules type/parse bugs and improved robustness for synthetic proxies.
  * Added `-RequireConfirmation` (default: enabled) to require interactive confirmation before destructive runs.
  * Safer cleanup: remove only empty top-level directories; never touch nested project folders.

**v1.1**

* Added support for optional configuration file (`-ConfigFile`) in JSON or PSD1 format.

**v1.0**

* Initial release with dry‑run, file/folder AND/OR rules, deep activity scan, archive‑extracted detection, extensive partial‑download excludes, Year/Month bucketing, robocopy large‑file moves, JSONL/CSV logging, empty‑folder cleanup, and
