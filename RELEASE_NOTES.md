# Downloads Auto-Archiver v1.0.0

**Initial Stable Release** — January 2026

---

## Overview

Downloads Auto-Archiver is a PowerShell script that safely and efficiently moves old or untouched items from your Windows **Downloads** folder to a **NAS or archive location** on a recurring schedule. Built for **Task Scheduler** with a **DryRun** mode for safe auditing before any files are moved.

---

## Key Features

### 📁 Smart File & Folder Rules
- **Time-based archiving** — Move files/folders based on age (CreationTime or LastWriteTime) and last access time
- **Flexible rule combinations** — Combine conditions with AND/OR logic
- **Deep folder activity scanning** — Optionally scan folder contents to detect recent activity before archiving

### 📦 Archive Detection
- **Extracted archive cleanup** — Automatically identifies and moves archive files (`.zip`, `.7z`, `.rar`, `.tar.*`, `.iso`) that have been extracted (sibling folder with matching name)
- **Grace period** — Configurable delay before moving freshly extracted archives

### 🛡️ Safety First
- **DryRun mode** — Audit all planned actions before executing
- **Interactive confirmation** — Optional prompt before destructive operations
- **In-progress file detection** — Skips partial downloads (`.crdownload`, `.part`, `.tmp`, etc.)
- **File-in-use detection** — Won't move files with open handles
- **Hidden file protection** — Optionally ignore hidden items

### 🔄 Robust File Operations
- **Robocopy integration** — Uses robocopy for large files (configurable threshold) for better reliability over networks
- **Conflict resolution** — Skip, overwrite, or rename with timestamp on destination conflicts
- **Year/Month bucketing** — Organizes archived files into `YYYY/MM` folder structure

### 📊 Comprehensive Logging
- **Dual format logging** — JSON Lines (`.jsonl`) and CSV formats
- **Local and remote logs** — Write logs to both local disk and network location
- **Verbose console output** — Optional detailed progress in Task Scheduler history

### ⚙️ Flexible Configuration
- **JSON or PSD1 config files** — Load settings from external configuration
- **Command-line overrides** — Parameters take precedence over config file
- **Sensible defaults** — Works out of the box with minimal configuration

### 🧹 Housekeeping
- **Empty folder cleanup** — Automatically removes empty top-level directories after moves
- **Operation limits** — Configurable max operations per run for safety
- **Free space checks** — Aborts if destination has insufficient space

---

## Installation

### From PowerShell Gallery
```powershell
Install-Script -Name Downloads-Auto-Archiver
```

### From GitHub
```powershell
# Download the script
Invoke-WebRequest -Uri "https://github.com/aalex954/downloads-auto-archiver/releases/latest/download/Downloads-Auto-Archiver.ps1" -OutFile "Downloads-Auto-Archiver.ps1"
```

---

## Quick Start

### 1. Dry Run (Audit Mode)
```powershell
.\Downloads-Auto-Archiver.ps1 -DestinationRoot "Z:\Archive" -DryRun $true -VerboseLog
```

### 2. Execute with Confirmation
```powershell
.\Downloads-Auto-Archiver.ps1 -DestinationRoot "Z:\Archive" -DryRun $false
```

### 3. Using a Config File
```powershell
.\Downloads-Auto-Archiver.ps1 -ConfigFile ".\config.json"
```

---

## Sample Configuration

```json
{
  "SourceDir": "C:\\Users\\YourName\\Downloads",
  "DestinationRoot": "\\\\NAS\\Archive",
  "DryRun": false,
  "FileOlderThan": "30.00:00:00",
  "FolderOlderThan": "45.00:00:00",
  "DeleteEmptyFolders": true
}
```

---

## Requirements

- Windows 10/11
- PowerShell 5.1 or PowerShell 7+
- Accessible destination (mapped drive or UNC path)

---

## Links

- 📖 [Full Documentation](https://github.com/aalex954/downloads-auto-archiver#readme)
- 🐛 [Report Issues](https://github.com/aalex954/downloads-auto-archiver/issues)
- 📦 [PowerShell Gallery](https://www.powershellgallery.com/packages/Downloads-Auto-Archiver)

---

## License

MIT License — See [LICENSE](https://github.com/aalex954/downloads-auto-archiver/blob/main/LICENSE) for details.
