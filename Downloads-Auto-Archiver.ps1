<#PSScriptInfo
.VERSION 1.0.0
.GUID 139b1b17-5955-4a1c-acde-1c39074edce9
.AUTHOR aalex954
.COMPANYNAME aalex954
.COPYRIGHT (c) 2026 aalex954. MIT License.
.TAGS Downloads Archive Cleanup NAS Automation TaskScheduler Windows
.LICENSEURI https://github.com/aalex954/downloads-auto-archiver/blob/main/LICENSE
.PROJECTURI https://github.com/aalex954/downloads-auto-archiver
.RELEASENOTES Initial stable release. See https://github.com/aalex954/downloads-auto-archiver/releases
#>

<#
.SYNOPSIS
    Safely moves old or untouched items from your Downloads folder to a NAS or archive location.
.DESCRIPTION
    Downloads Auto-Archiver efficiently moves old or untouched items from your Windows Downloads 
    folder to a NAS or mapped drive on a recurring schedule. Built for Task Scheduler with 
    DryRun mode for safe auditing before any files are moved.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
[string]$SourceDir = "$env:USERPROFILE\Downloads",
[string]$DestinationRoot,
[bool]$DryRun = $false,
[switch]$VerboseLog = $false,
[string]$LocalLogDir = "$env:USERPROFILE\\DownloadsAutoArchiver\\logs",
[string]$RemoteLogDir = $null,
[string]$ConfigFile = $null,
[bool]$RequireConfirmation = $true,    # <--- NEW: require interactive confirmation before any deletions/moves that remove source files

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

# -------------------------- Config file loading --------------------------

if ($ConfigFile) {
    try {
        $configExt = [System.IO.Path]::GetExtension($ConfigFile).ToLowerInvariant()
        if ($configExt -eq '.json') {
            $configData = Get-Content -Raw -LiteralPath $ConfigFile | ConvertFrom-Json
        } elseif ($configExt -eq '.psd1') {
            $configData = Import-PowerShellDataFile -Path $ConfigFile
        } else {
            throw "Unsupported config file format: $ConfigFile"
        }
        # Only override parameters NOT set via command line
        $bound = $PSBoundParameters.Keys
        foreach ($key in $configData.PSObject.Properties.Name) {
            if ($bound -contains $key) { continue }
            Set-Variable -Name $key -Value $configData.$key -Scope Script
        }
        Write-Host "Loaded configuration from $ConfigFile"
    } catch {
        throw "Failed to load config file: $ConfigFile :: $($_.Exception.Message)"
    }
}

if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
    throw "DestinationRoot parameter is required. Please specify a destination path."
}

$dirsToEnsure = @()
if ($LocalLogDir)   { $dirsToEnsure += $LocalLogDir }
if ($RemoteLogDir)  { $dirsToEnsure += $RemoteLogDir }
if ($DestinationRoot) { $dirsToEnsure += $DestinationRoot }

foreach ($d in $dirsToEnsure | Select-Object -Unique) {
    if ([string]::IsNullOrWhiteSpace($d)) { continue }
    try {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -Path $d -ItemType Directory -Force | Out-Null
            if ($VerboseLog) { Write-Host "Created directory: $d" }
        }
    } catch {
        Write-Host "WARN: Could not create directory '$d': $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

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
    if (-not (Test-Path $Path)) { return $false }
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
        [Parameter(Mandatory)][object]$Item,
        [Nullable[TimeSpan]]$UntouchedOlderThan,
        [Nullable[TimeSpan]]$OlderThan,
        [ValidateSet('AND','OR')][string]$Combine,
        [ValidateSet('CreationTime','LastWriteTime')][string]$AgeProperty
    )
    $now = Get-Date

    # Safely read time properties from either FileSystemInfo or a synthetic PSCustomObject
    $itemLastAccess   = $null
    $itemLastWrite    = $null
    $itemCreationTime = $null

    if ($Item -ne $null) {
        if ($Item -is [System.IO.FileSystemInfo]) {
            $itemLastAccess   = $Item.LastAccessTime
            $itemLastWrite    = $Item.LastWriteTime
            $itemCreationTime = $Item.CreationTime
        } else {
            # Attempt dynamic property access for PSCustomObject or hashtable
            if ($Item.PSObject.Properties.Match('LastAccessTime'))  { $itemLastAccess   = $Item.LastAccessTime  }
            if ($Item.PSObject.Properties.Match('LastWriteTime'))   { $itemLastWrite    = $Item.LastWriteTime   }
            if ($Item.PSObject.Properties.Match('CreationTime'))    { $itemCreationTime = $Item.CreationTime    }
        }
    }

    # Ensure fallback values are valid datetimes
    if (-not ($itemLastAccess -is [datetime]))   { $itemLastAccess   = [datetime]'1900-01-01' }
    if (-not ($itemLastWrite  -is [datetime]))   { $itemLastWrite    = [datetime]'1900-01-01' }
    if (-not ($itemCreationTime -is [datetime])) { $itemCreationTime = [datetime]'1900-01-01' }

    $untouchedOk = $false
    if ($UntouchedOlderThan) {
        # If LastAccessTime looks uninitialized, fallback to LastWriteTime
        $accessTime = if ($itemLastAccess -gt [datetime]'1900-01-01') { $itemLastAccess } else { $itemLastWrite }
        $untouchedOk = ($now - $accessTime) -ge $UntouchedOlderThan
    }

    $ageOk = $false
    if ($OlderThan) {
        $agePropVal = if ($AgeProperty -eq 'CreationTime') { $itemCreationTime } else { $itemLastWrite }
        $ageOk = ($now - $agePropVal) -ge $OlderThan
    }

    if ($UntouchedOlderThan -and $OlderThan) {
        if ($Combine -eq 'AND') {
            return ($untouchedOk -and $ageOk)
        } else {
            return ($untouchedOk -or $ageOk)
        }
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
    $year = Get-Date -Format 'yyyy'
    $month = Get-Date -Format 'MM'
    $dstDir = Join-Path $DestinationRoot $year $month  # year/month bucketing (cross-platform)
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

# -------------------------- Confirmation before destructive actions --------------------------

if ($RequireConfirmation -and -not $DryRun) {
    $moveCount = $toMove.Count
    if ($moveCount -gt 0) {
        # Summarize planned operations
        $summaryLines = @()
        $summaryLines += "Planned operations: $moveCount item(s) will be moved (this will remove source items)."
        # show a small sample
        $sample = $toMove | Select-Object -First 10 | ForEach-Object { "{0} -> {1}" -f $_.Item.FullName, (Resolve-DestinationPath -Item $_.Item) }
        if ($toMove.Count -gt 10) { $sample += "... (and more)" }
        $summaryLines += ""
        $summaryLines += "Sample planned moves (first 10):"
        $summaryLines += $sample

        # Log summary
        Write-LogEntry -Level 'WARN' -Message ($summaryLines -join "`n")

        # Interactive prompt (fail-safe for non-interactive hosts)
        $choice = $null
        try {
            $choices = @([System.Management.Automation.Host.ChoiceDescription]::new("&Yes","Proceed with moves and deletions"),
                         [System.Management.Automation.Host.ChoiceDescription]::new("&No","Abort; do not perform moves"))
            $caption = "Downloads Auto-Archiver: confirm destructive actions"
            $message = "This run will move $moveCount item(s) and remove the source files. Proceed?"
            $choiceIdx = $Host.UI.PromptForChoice($caption, $message, $choices, 1)
            $choice = $choiceIdx
        } catch {
            # Host not interactive - abort to be safe
            Write-LogEntry -Level 'ERROR' -Message "Non-interactive host and RequireConfirmation enabled: aborting to avoid destructive actions."
            throw "RequireConfirmation is enabled but no interactive prompt is available. Re-run with -RequireConfirmation:$false to skip confirmation in non-interactive contexts."
        }

        if ($choice -ne 0) {
            Write-LogEntry -Level 'WARN' -Message "User aborted run via confirmation prompt. No files were moved or deleted."
            exit 0
        } else {
            Write-LogEntry -Level 'INFO' -Message "User confirmed destructive actions; proceeding with moves."
        }
    } else {
        # Nothing to move; safe to continue (no destructive actions)
        Write-LogEntry -Message "No items selected for move; nothing to confirm."
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

# -------------------------- Cleanup: delete empty top-level folders only (safer) --------------------------
# Policy: do NOT touch nested folders. Only remove empty immediate children of $SourceDir
# Respect DryRun and RequireConfirmation (interactive). Skip hidden/excluded items.
if ($DeleteEmptyFolders) {
    $deleted = 0

    # Grab immediate child directories only (top-level)
    try {
        $topLevelDirs = Get-ChildItem -LiteralPath $SourceDir -Directory -Force -ErrorAction Stop
    } catch {
        Write-LogEntry -Level 'WARN' -Message "Failed to enumerate top-level directories under $($SourceDir): $($_.Exception.Message)"
        $topLevelDirs = @()
    }

    # If destructive actions require confirmation and we are about to perform real deletions,
    # prompt the user (skip prompt for DryRun). If an earlier confirmation already occurred this run,
    # set $script:ConfirmedDestructive to avoid double prompts.
    $needsConfirmation = ($RequireConfirmation -and -not $DryRun)
    if ($needsConfirmation -and -not (Get-Variable -Name ConfirmedDestructive -Scope Script -ErrorAction SilentlyContinue)) {
        # Only prompt when there are top-level empties that would be deleted (compute quickly)
        $wouldDeleteCount = 0
        foreach ($d in $topLevelDirs) {
            try {
                $hasChildren = (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction Stop | Measure-Object).Count -gt 0
                if (-not $hasChildren) {
                    if ($IgnoreHidden -and ($d.Attributes -band [IO.FileAttributes]::Hidden)) { continue }
                    if (-not (Test-Patterns -Item $d -Includes $IncludePatterns -Excludes $ExcludePatterns)) { continue }
                    $wouldDeleteCount++
                }
            } catch { continue }
        }

        if ($wouldDeleteCount -gt 0) {
            try {
                $choices = @(
                    [System.Management.Automation.Host.ChoiceDescription]::new("&Yes","Proceed with removing empty top-level directories"),
                    [System.Management.Automation.Host.ChoiceDescription]::new("&No","Abort; do not remove directories")
                )
                $caption = "Downloads Auto-Archiver: confirm empty-directory removals"
                $message = "This run would remove $wouldDeleteCount empty top-level directory(ies) under $SourceDir. Proceed?"
                $choiceIdx = $Host.UI.PromptForChoice($caption, $message, $choices, 1)
                if ($choiceIdx -ne 0) {
                    Write-LogEntry -Level 'WARN' -Message "User aborted empty-directory cleanup. No directories were removed."
                    $topLevelDirs = @()  # skip deletion loop
                } else {
                    # mark that destructive actions were confirmed this run
                    Set-Variable -Name ConfirmedDestructive -Scope Script -Value $true -Force
                    Write-LogEntry -Level 'INFO' -Message "User confirmed empty-directory cleanup; proceeding."
                }
            } catch {
                Write-LogEntry -Level 'ERROR' -Message "RequireConfirmation enabled but host is non-interactive; skipping empty-directory cleanup to avoid destructive actions."
                $topLevelDirs = @()  # skip deletion loop
            }
        }
    }

    foreach ($dir in $topLevelDirs) {
        try {
            $hasChildren = (Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction Stop | Measure-Object).Count -gt 0
            if ($hasChildren) { continue }

            # Respect hidden flag and include/exclude patterns
            if ($IgnoreHidden -and ($dir.Attributes -band [IO.FileAttributes]::Hidden)) { continue }
            if (-not (Test-Patterns -Item $dir -Includes $IncludePatterns -Excludes $ExcludePatterns)) { continue }

            if ($DryRun) {
                Write-LogEntry -Message "[DRYRUN] Would remove empty top-level directory: $($dir.FullName)"
            } else {
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
                $deleted++
                Write-LogEntry -Message "Removed empty top-level directory: $($dir.FullName)"
            }
        } catch {
            Write-LogEntry -Level 'WARN' -Message "Failed to evaluate/delete top-level dir $($dir.FullName): $($_.Exception.Message)"
        }
    }

    if ($deleted -gt 0) { Write-LogEntry -Message "Deleted empty top-level folders: $deleted" }
}

Write-LogEntry -Message "Completed. Operations performed: $ops (DryRun=$DryRun)"
