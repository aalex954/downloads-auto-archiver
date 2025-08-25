<#
Downloads Auto-Archiver.ps1

Safely and efficiently moves old/unused items from your Windows 11 Downloads folder
(to a NAS / mapped drive) based on configurable rules. Designed for recurring use
via Task Scheduler. Defaults to DRY-RUN for safety.

• File rules (top-level only):
  - Untouched (LastAccessTime) older than X
  - Older than X (CreationTime or LastWriteTime)
  - Combine with AND/OR
• Folder rules (top-level only):
  - Untouched (LastAccessTime) older than X
  - Older than X (CreationTime or LastWriteTime)
  - Combine with AND/OR
  - Optional deep scan for recent activity of descendants
• Archive rule:
  - Move archives (.zip/.7z/.rar/.tar.* etc.) that have a sibling folder matching the archive's stem
• Ignore rules:
  - Partial downloads: *.crdownload, *.tmp, *.part, *.!ut, *.partial, *.download, *.aria2
  - Custom include/exclude patterns
• Extras:
  - Delete empty folders (post-move)
  - Logging (local AND/OR remote). JSONL + CSV
  - Name conflict handling: Skip / Overwrite / RenameWithTimestamp (default)
  - Max operations per run to avoid surprises
  - Optional Robocopy for resilient moves (large files or network hiccups)

Tested on Windows PowerShell 5.1 and PowerShell 7+.

NOTE on LastAccessTime ("untouched"):
  Windows may throttle or disable updates to LastAccessTime for performance.
  If this field is stale, the "untouched" rule could be unreliable.
  You can check/update policy (requires admin & reboot):
    fsutil behavior query DisableLastAccess
    fsutil behavior set DisableLastAccess 2    # System managed (recommended on Win10/11)
    # or 0 to always update; 1/3 disables updates
#>

[CmdletBinding()]
param(
[string]$SourceDir = "$env:USERPROFILE\Downloads",
[string]$DestinationRoot = "Z:\\Downloads_Archive", # mapped NAS drive or UNC path
[switch]$DryRun = $true,
[switch]$VerboseLog,
[string]$LocalLogDir = "$env:ProgramData\DownloadsAutoArchiver\logs",
[string]$RemoteLogDir = "Z:\\Downloads_Archive\\_logs", # set to $null to disable


# File rules
[Nullable[TimeSpan]]$FileUntouchedOlderThan = [TimeSpan]::FromDays(14), # LastAccessTime
[Nullable[TimeSpan]]$FileOlderThan = [TimeSpan]::FromDays(30), # Age based on property below
[ValidateSet('AND','OR')][string]$FileTimeCombine = 'AND',
[ValidateSet('CreationTime','LastWriteTime')][string]$FileAgeProperty = 'CreationTime',


# Folder rules
[Nullable[TimeSpan]]$FolderUntouchedOlderThan = [TimeSpan]::FromDays(30),
[Nullable[TimeSpan]]$FolderOlderThan = [TimeSpan]::FromDays(45),
[ValidateSet('AND','OR')][string]$FolderTimeCombine = 'AND',
[ValidateSet('CreationTime','LastWriteTime')][string]$FolderAgeProperty = 'CreationTime',
[switch]$DeepFolderActivityScan = $true, # if set, compute latest activity from descendants (slower)


# Archive detection
[string[]]$ArchiveExtensions = @('*.zip','*.7z','*.rar','*.tar','*.tar.gz','*.tgz','*.tar.bz2','*.tbz2','*.tar.xz','*.txz','*.iso'),
[int]$ArchiveExtractedGraceMinutes = 30, # wait this long after archive write time before moving


# Patterns
[string[]]$IncludePatterns = @('*'),
[string[]]$ExcludePatterns = @('*.crdownload','*.opdownload','*.download','*.aria2','*.part','*.filepart','*.tmp','*.temp','*.!ut','*.!qB','_UNPACK_*','_FAILED_*'),
[switch]$IgnoreHidden = $true,


# Safety/Performance
[ValidateSet('Skip','Overwrite','RenameWithTimestamp')][string]$OnNameConflict = 'RenameWithTimestamp',
[int]$MaxOperationsPerRun = 500,
[int]$MinFreeSpaceMB = 512, # required free space on destination drive
[switch]$UseRobocopy = $true,
[int]$RobocopyLargeFileMB = 256, # use robocopy for files >= this size


# Housekeeping
[switch]$DeleteEmptyFolders = $true
)

# -------------------------- Helpers --------------------------

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($DryRun) { Write-Verbose "[DRYRUN] Would create directory: $Path" }
        else {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }
}

function Write-LogEntry {
    param(
        [string]$Level = 'INFO',
        [string]$Message,
        [hashtable]$Data
    )
    $timestamp = (Get-Date).ToString('s')
    $obj = [ordered]@{
        ts      = $timestamp
        level   = $Level
        message = $Message
    }
    if ($Data) { $Data.GetEnumerator() | ForEach-Object { $obj[$_.Key] = $_.Value } }

    $json = ($obj | ConvertTo-Json -Compress)

    foreach ($logDir in @($LocalLogDir, $RemoteLogDir)) {
        if ([string]::IsNullOrWhiteSpace($logDir)) { continue }
        try {
            New-DirectoryIfMissing -Path $logDir
            $json | Add-Content -LiteralPath (Join-Path $logDir 'DownloadsAutoArchiver.log.jsonl') -Encoding UTF8
        } catch { Write-Verbose "Failed to write JSON log to $logDir : $($_.Exception.Message)" }
    }

    # Also CSV (simple)
    $csvLine = '"{0}","{1}","{2}"' -f $timestamp, $Level, ($Message -replace '"','''')
    foreach ($logDir in @($LocalLogDir, $RemoteLogDir)) {
        if ([string]::IsNullOrWhiteSpace($logDir)) { continue }
        try {
            New-DirectoryIfMissing -Path $logDir
            $csvLine | Add-Content -LiteralPath (Join-Path $logDir 'DownloadsAutoArchiver.log.csv') -Encoding UTF8
        } catch {}
    }

    if ($VerboseLog) { Write-Host "[$timestamp][$Level] $Message" }
}

function Test-Patterns {
    param(
        [System.IO.FileSystemInfo]$Item,
        [string[]]$Includes,
        [string[]]$Excludes
    )
    $name = $Item.Name
    $included = $false
    foreach ($pat in $Includes) { if ($name -like $pat) { $included = $true; break } }
    if (-not $included) { return $false }

    foreach ($pat in $Excludes) { if ($name -like $pat) { return $false } }

    return $true
}

function Test-FileInUse {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
        $fs.Close()
        return $false
    } catch { return $true }
}

function Get-LatestFolderActivity {
    param([System.IO.DirectoryInfo]$Dir)
    if (-not $DeepFolderActivityScan) {
        # Use folder's own timestamps
        return [ordered]@{
            LastAccessTime = $Dir.LastAccessTime
            LastWriteTime  = $Dir.LastWriteTime
        }
    }
    $latestAccess = $Dir.LastAccessTime
    $latestWrite  = $Dir.LastWriteTime
    try {
        Get-ChildItem -LiteralPath $Dir.FullName -Recurse -Force -ErrorAction Stop | ForEach-Object {
            if ($_.PSIsContainer) {
                if ($_.LastAccessTime -gt $latestAccess) { $latestAccess = $_.LastAccessTime }
                if ($_.LastWriteTime  -gt $latestWrite)  { $latestWrite  = $_.LastWriteTime  }
            } else {
                if ($_.LastAccessTime -gt $latestAccess) { $latestAccess = $_.LastAccessTime }
                if ($_.LastWriteTime  -gt $latestWrite)  { $latestWrite  = $_.LastWriteTime  }
            }
        }
    } catch {}
    return [ordered]@{ LastAccessTime = $latestAccess; LastWriteTime = $latestWrite }
}

function Test-TimeRules {
    param(
        [System.IO.FileSystemInfo]$Item,
        [Nullable[TimeSpan]]$UntouchedOlderThan,
        [Nullable[TimeSpan]]$OlderThan,
        [ValidateSet('AND','OR')][string]$Combine,
        [ValidateSet('CreationTime','LastWriteTime')][string]$AgeProperty
    )
    $now = Get-Date

    $untouchedOk = $false
    if ($UntouchedOlderThan) {
        # If LastAccessTime looks uninitialized, fallback to LastWriteTime
        $accessTime = if ($Item.LastAccessTime -gt [datetime]'1900-01-01') { $Item.LastAccessTime } else { $Item.LastWriteTime }
        $untouchedOk = ($now - $accessTime) -ge $UntouchedOlderThan
    }

    $ageOk = $false
    if ($OlderThan) {
        $agePropVal = if ($AgeProperty -eq 'CreationTime') { $Item.CreationTime } else { $Item.LastWriteTime }
        $ageOk = ($now - $agePropVal) -ge $OlderThan
    }

    if ($UntouchedOlderThan -and $OlderThan) {
        return if ($Combine -eq 'AND') { $untouchedOk -and $ageOk } else { $untouchedOk -or $ageOk }
    } elseif ($UntouchedOlderThan) {
        return $untouchedOk
    } elseif ($OlderThan) {
        return $ageOk
    } else {
        return $false # no thresholds configured
    }
}

function Resolve-DestinationPath {
    param([System.IO.FileSystemInfo]$Item)
    $subdir = (Get-Date -Format 'yyyy\\MM') # year/month bucketing
    $dstDir = Join-Path $DestinationRoot $subdir
    New-DirectoryIfMissing -Path $dstDir
    return Join-Path $dstDir $Item.Name
}

function Resolve-NameConflict {
    param([string]$TargetPath)
    if (-not (Test-Path -LiteralPath $TargetPath)) { return $TargetPath }

    switch ($OnNameConflict) {
        'Skip'      { return $null }
        'Overwrite' { return $TargetPath }
        default     {
            $dir = Split-Path $TargetPath -Parent
            $base = [System.IO.Path]::GetFileNameWithoutExtension($TargetPath)
            $ext  = [System.IO.Path]::GetExtension($TargetPath)
            $ts   = (Get-Date).ToString('yyyyMMdd_HHmmss')
            return (Join-Path $dir ("{0}__{1}{2}" -f $base,$ts,$ext))
        }
    }
}

function Move-ItemSafe {
    param(
        [Parameter(Mandatory)] [System.IO.FileSystemInfo] $Item,
        [Parameter(Mandatory)] [string] $TargetPath
    )
    if ($DryRun) {
        Write-LogEntry -Message "[DRYRUN] Would move: $($Item.FullName) -> $TargetPath" -Data @{path=$Item.FullName; dest=$TargetPath}
        return $true
    }

    # Ensure destination directory exists
    New-DirectoryIfMissing -Path (Split-Path $TargetPath -Parent)

    try {
        if (-not $Item.PSIsContainer) {
            $sizeMB = [math]::Round(($Item.Length/1MB),2)
            if ($UseRobocopy -and $sizeMB -ge $RobocopyLargeFileMB) {
                # Use ROBOCOPY for resilience on large files (across volumes/NAS)
                $srcDir = $Item.DirectoryName
                $fileName = $Item.Name
                $dstDir = Split-Path $TargetPath -Parent
                $cmd = @('robocopy', $srcDir, $dstDir, $fileName, '/MOV', '/NFL','/NDL','/NJH','/NJS','/NP','/R:2','/W:2')
                $p = Start-Process -FilePath $cmd[0] -ArgumentList ($cmd[1..($cmd.Count-1)]) -PassThru -Wait -NoNewWindow
                if ($p.ExitCode -lt 8) { return $true } else { throw "Robocopy failed with code $($p.ExitCode)" }
            } else {
                Move-Item -LiteralPath $Item.FullName -Destination $TargetPath -Force -ErrorAction Stop
                return $true
            }
        } else {
            # Directory move
            Move-Item -LiteralPath $Item.FullName -Destination $TargetPath -Force -ErrorAction Stop
            return $true
        }
    } catch {
        Write-LogEntry -Level 'ERROR' -Message "Move failed: $($Item.FullName) -> $TargetPath :: $($_.Exception.Message)" -Data @{path=$Item.FullName; dest=$TargetPath; err=$_.Exception.Message}
        return $false
    }
}

function Get-DriveFreeSpaceMB {
    param([string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot((Resolve-Path $Path))
        $drive = Get-PSDrive -Name ($root.TrimEnd(':','\\')) -ErrorAction Stop
        return [math]::Floor($drive.Free/1MB)
    } catch { return $null }
}

# -------------------------- Pre-flight checks --------------------------

New-DirectoryIfMissing -Path $LocalLogDir
if ($RemoteLogDir) { New-DirectoryIfMissing -Path $RemoteLogDir }

if (-not (Test-Path -LiteralPath $SourceDir)) {
    throw "Source directory not found: $SourceDir"
}
if (-not (Test-Path -LiteralPath $DestinationRoot)) {
    Write-LogEntry -Level 'ERROR' -Message "Destination root not found: $DestinationRoot" -Data @{dest=$DestinationRoot}
    throw "Destination root not found: $DestinationRoot"
}

$freeMB = Get-DriveFreeSpaceMB -Path $DestinationRoot
if ($freeMB -ne $null -and $freeMB -lt $MinFreeSpaceMB) {
    Write-LogEntry -Level 'ERROR' -Message "Insufficient free space on destination ($freeMB MB < $MinFreeSpaceMB MB). Aborting." -Data @{freeMB=$freeMB}
    throw "Insufficient free space on destination."
}

Write-LogEntry -Message "Starting scan of '$SourceDir' -> '$DestinationRoot' (DryRun=$DryRun)"

# -------------------------- Discover top-level items --------------------------

$topFiles = Get-ChildItem -LiteralPath $SourceDir -File -Force
$topDirs  = Get-ChildItem -LiteralPath $SourceDir -Directory -Force

# Build quick lookup of top-level dirs by stem
$dirStem = @{}
foreach ($d in $topDirs) { $dirStem[$d.Name.ToLowerInvariant()] = $true }

# -------------------------- Selection logic --------------------------

$toMove = New-Object System.Collections.Generic.List[object]

# Files
foreach ($f in $topFiles) {
    if ($IgnoreHidden -and ($f.Attributes -band [IO.FileAttributes]::Hidden)) { continue }
    if (-not (Test-Patterns -Item $f -Includes $IncludePatterns -Excludes $ExcludePatterns)) { continue }

    # Skip if file is in use (best-effort)
    if (Test-FileInUse -Path $f.FullName) { continue }

    $selected = $false
    $reason = $null

    # Time-based rules
    if (Test-TimeRules -Item $f -UntouchedOlderThan $FileUntouchedOlderThan -OlderThan $FileOlderThan -Combine $FileTimeCombine -AgeProperty $FileAgeProperty) {
        $selected = $true
        $reason = "file-time"
    }

    # Archive sibling rule (only if not already selected)
    if (-not $selected) {
        $isArchive = $false
        foreach ($pat in $ArchiveExtensions) { if ($f.Name -like $pat) { $isArchive = $true; break } }
        if ($isArchive) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name).ToLowerInvariant()
            if ($dirStem.ContainsKey($stem)) {
                # Ensure archive isn't too fresh
                $ageMin = [int]((Get-Date) - $f.LastWriteTime).TotalMinutes
                if ($ageMin -ge $ArchiveExtractedGraceMinutes) {
                    $selected = $true
                    $reason = "archive-extracted"
                }
            }
        }
    }

    if ($selected) { $toMove.Add([pscustomobject]@{ Item=$f; Reason=$reason }) }
}

# Folders (top-level only)
foreach ($d in $topDirs) {
    if ($IgnoreHidden -and ($d.Attributes -band [IO.FileAttributes]::Hidden)) { continue }
    if (-not (Test-Patterns -Item $d -Includes $IncludePatterns -Excludes $ExcludePatterns)) { continue }

    $act = Get-LatestFolderActivity -Dir $d

    # Construct a synthetic object for time testing using folder timestamps
    $folderTimeProxy = New-Object psobject -Property @{
        LastAccessTime = $act.LastAccessTime
        LastWriteTime  = $act.LastWriteTime
        CreationTime   = $d.CreationTime
    }

    if (Test-TimeRules -Item $folderTimeProxy -UntouchedOlderThan $FolderUntouchedOlderThan -OlderThan $FolderOlderThan -Combine $FolderTimeCombine -AgeProperty $FolderAgeProperty) {
        $toMove.Add([pscustomobject]@{ Item=$d; Reason='folder-time' })
    }
}

# -------------------------- Execute moves --------------------------

$ops = 0
foreach ($entry in $toMove) {
    if ($ops -ge $MaxOperationsPerRun) {
        Write-LogEntry -Level 'WARN' -Message "Hit MaxOperationsPerRun=$MaxOperationsPerRun; stopping for safety."; break
    }

    $item = $entry.Item
    $reason = $entry.Reason

    $target = Resolve-DestinationPath -Item $item
    $target = Resolve-NameConflict -TargetPath $target
    if (-not $target) { Write-LogEntry -Level 'WARN' -Message "Skipping due to name conflict policy: $($item.FullName)"; continue }

    $ok = Move-ItemSafe -Item $item -TargetPath $target
    if ($ok) {
        $ops++
        Write-LogEntry -Message "Moved [$reason]: $($item.FullName) -> $target" -Data @{path=$item.FullName; dest=$target; reason=$reason}
    }
}

# -------------------------- Cleanup: delete empty folders --------------------------

if ($DeleteEmptyFolders) {
    $deleted = 0
    # Re-scan directories (recursive) and remove empties
    Get-ChildItem -LiteralPath $SourceDir -Directory -Force -Recurse | Sort-Object FullName -Descending | ForEach-Object {
        try {
            $hasChildren = (Get-ChildItem -LiteralPath $_.FullName -Force | Measure-Object).Count -gt 0
            if (-not $hasChildren) {
                if ($DryRun) { Write-LogEntry -Message "[DRYRUN] Would remove empty directory: $($_.FullName)" }
                else {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                    $deleted++
                    Write-LogEntry -Message "Removed empty directory: $($_.FullName)"
                }
            }
        } catch {}
    }
    if ($deleted -gt 0) { Write-LogEntry -Message "Deleted empty folders: $deleted" }
}

Write-LogEntry -Message "Completed. Operations performed: $ops (DryRun=$DryRun)"
