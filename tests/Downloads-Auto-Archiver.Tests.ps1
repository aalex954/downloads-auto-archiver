# Pester-based unit tests for Downloads-Auto-Archiver.ps1

BeforeAll {
    # Robustly determine project root (PSScriptRoot may be null during some discovery runs)
    $projectRoot = $null
    if ($PSScriptRoot) {
        $projectRoot = Split-Path -Parent $PSScriptRoot
    }
    if (-not $projectRoot) {
        if ($MyInvocation.MyCommand.Definition) {
            $projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
        }
    }
    if (-not $projectRoot) {
        $current = Get-Location
        if ($current) {
            $projectRoot = Split-Path -Parent $current.Path
        }
    }
    if (-not $projectRoot) {
        throw "Cannot determine project root"
    }

    # Use the tests directory itself as the test root for all activities
    $localTestRoot = $PSScriptRoot

    # Clean any existing test artifacts in the tests directory (preserve the test script)
    Get-ChildItem $localTestRoot -File | Where-Object { $_.Name -ne 'Downloads-Auto-Archiver.Tests.ps1' } | Remove-Item -Force
    Get-ChildItem $localTestRoot -Directory | Remove-Item -Recurse -Force

    $Script:TestRoot = $localTestRoot
    $global:TestRoot = $localTestRoot

    # Create subdirectories for test setup
    $localLogDir = Join-Path $localTestRoot 'logs'
    $localDestRoot = Join-Path $localTestRoot 'dest'
    $localTestSrc = Join-Path $localTestRoot 'src'

    New-Item -Path $localLogDir -ItemType Directory -Force | Out-Null
    New-Item -Path $localDestRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $localTestSrc -ItemType Directory -Force | Out-Null

    $Script:LocalLogDir = $localLogDir
    $Script:DestinationRoot = $localDestRoot

    # Logging all variables configured up to this point
    Write-Host "Configured variables up to this point:"
    Write-Host "projectRoot: $projectRoot"
    Write-Host "localTestRoot: $localTestRoot"
    Write-Host "Script:TestRoot: $($Script:TestRoot)"
    Write-Host "global:TestRoot: $($global:TestRoot)"
    Write-Host "localLogDir: $localLogDir"
    Write-Host "localDestRoot: $localDestRoot"
    Write-Host "localTestSrc: $localTestSrc"

    # Dot-source the script under test with the prepared directories
    . (Join-Path $projectRoot 'Downloads-Auto-Archiver.ps1') `
        -SourceDir $localTestSrc `
        -DestinationRoot $localDestRoot `
        -DryRun:$true `
        -LocalLogDir $localLogDir `
        -RemoteLogDir $null `
        -RequireConfirmation:$false `
        -UseRobocopy:$false `
        -VerboseLog:$false

    # Ensure script-scoped flags are set as expected (tests may tweak these later)
    $DryRun      = $true
    $UseRobocopy  = $false
}

Describe "Downloads Auto-Archiver - unit tests" {
    Context "New-DirectoryIfMissing" {
        It "creates directory when DryRun is false" {
            $path = Join-Path $Script:TestRoot 'createdir_real'
            if (Test-Path $path) { Remove-Item -Recurse -Force $path }
            $DryRun = $false
            New-DirectoryIfMissing -Path $path
            (Test-Path $path) | Should -BeTrue
            Remove-Item -Recurse -Force $path
            $DryRun = $true
        }
        It "does not create directory when DryRun is true" {
            $path = Join-Path $Script:TestRoot 'createdir_dry'
            if (Test-Path $path) { Remove-Item -Recurse -Force $path }
            $DryRun = $true
            New-DirectoryIfMissing -Path $path
            (Test-Path $path) | Should -BeFalse
        }
    }

    Context "Write-LogEntry" {
        It "writes JSONL and CSV logs to LocalLogDir" {
            $DryRun = $false
            Write-LogEntry -Level 'INFO' -Message 'unit-test-log' -Data @{test='x'}
            $jsonFile = Join-Path $Script:LocalLogDir 'DownloadsAutoArchiver.log.jsonl'
            $csvFile  = Join-Path $Script:LocalLogDir 'DownloadsAutoArchiver.log.csv'
            (Test-Path $jsonFile) | Should -BeTrue
            (Test-Path $csvFile)  | Should -BeTrue
            (Get-Content $jsonFile -ErrorAction Stop | Select-String 'unit-test-log') | Should -Not -BeNullOrEmpty
            (Get-Content $csvFile  -ErrorAction Stop | Select-String 'unit-test-log') | Should -Not -BeNullOrEmpty
            $DryRun = $true
        }
    }

    Context "Test-Patterns" {
        It "accepts includes and rejects excludes correctly" {
            $f = New-Item -Path (Join-Path $Script:TestRoot 'sample.test') -ItemType File -Force
            $fi = Get-Item $f.FullName
            (Test-Patterns -Item $fi -Includes @('*.test') -Excludes @()) | Should -BeTrue
            (Test-Patterns -Item $fi -Includes @('*.nope') -Excludes @()) | Should -BeFalse
            Remove-Item $f -Force
        }
    }

    Context "Test-FileInUse" {
        It "detects an open file handle" {
            $file = New-Item -Path (Join-Path $Script:TestRoot 'lockme.txt') -ItemType File -Force
            $fs = [System.IO.File]::Open($file.FullName,'Open','Read','None')
            try {
                (Test-FileInUse -Path $file.FullName) | Should -BeTrue
            } finally {
                $fs.Close()
                Remove-Item $file -Force
            }
            # file removed -> not in use
            (Test-FileInUse -Path $file.FullName) | Should -BeFalse
        }
    }

    Context "Get-LatestFolderActivity" {
        It "returns latest descendant timestamps when DeepFolderActivityScan is enabled" {
            $DeepFolderActivityScan = $true
            $dir = New-Item -Path (Join-Path $Script:TestRoot 'dir_activity') -ItemType Directory -Force
            $dir.LastWriteTime = (Get-Date).AddDays(-10)
            $child = New-Item -Path (Join-Path $dir.FullName 'recent.txt') -ItemType File -Force
            $recent = (Get-Date).AddSeconds(10)
            (Get-Item $child.FullName).LastWriteTime = $recent
            $act = Get-LatestFolderActivity -Dir (Get-Item $dir.FullName)
            $act.LastWriteTime | Should -Be $recent
        }
    }

    Context "Test-TimeRules" {
        It "correctly evaluates UntouchedOlderThan and OlderThan with AND/OR combinations" {
            $now = Get-Date
            $obj = [pscustomobject]@{
                LastAccessTime = $now.AddDays(-10)
                LastWriteTime  = $now.AddDays(-40)
                CreationTime   = $now.AddDays(-40)
            }
            (Test-TimeRules -Item $obj -UntouchedOlderThan ([TimeSpan]::FromDays(7)) -OlderThan ([TimeSpan]::FromDays(30)) -Combine 'AND' -AgeProperty 'CreationTime') | Should -BeTrue
            (Test-TimeRules -Item $obj -UntouchedOlderThan ([TimeSpan]::FromDays(7)) -OlderThan ([TimeSpan]::FromDays(30)) -Combine 'OR'  -AgeProperty 'CreationTime') | Should -BeTrue
            $fresh = [pscustomobject]@{
                LastAccessTime = $now.AddDays(-1)
                LastWriteTime  = $now.AddDays(-1)
                CreationTime   = $now.AddDays(-1)
            }
            (Test-TimeRules -Item $fresh -UntouchedOlderThan ([TimeSpan]::FromDays(7)) -OlderThan ([TimeSpan]::FromDays(30)) -Combine 'AND' -AgeProperty 'CreationTime') | Should -BeFalse
        }
    }

    Context "Resolve-DestinationPath & Resolve-NameConflict" {
        It "builds yyyy/MM destination and applies conflict policy" {
            $DestinationRoot = Join-Path $Script:TestRoot 'destroot'
            New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
            $srcFile = New-Item -Path (Join-Path $Script:TestRoot 'source.txt') -ItemType File -Force
            $dst = Resolve-DestinationPath -Item (Get-Item $srcFile.FullName)
            # Check for year/month pattern in path (cross-platform)
            $expectedYear = (Get-Date -Format 'yyyy')
            $expectedMonth = (Get-Date -Format 'MM')
            $dst -match "$expectedYear[/\\]$expectedMonth" | Should -BeTrue
            # create a file at destination to simulate conflict
            New-Item -Path $dst -ItemType File -Force | Out-Null
            $OnNameConflict = 'Skip'
            (Resolve-NameConflict -TargetPath $dst) | Should -Be $null
            $OnNameConflict = 'Overwrite'
            (Resolve-NameConflict -TargetPath $dst) | Should -Be $dst
            $OnNameConflict = 'RenameWithTimestamp'
            (Resolve-NameConflict -TargetPath $dst) | Should -Not -Be $null
            Remove-Item $srcFile -Force
        }
    }

    Context "Move-ItemSafe (DryRun behavior)" {
        It "returns true and does not move file when DryRun is enabled" {
            $DryRun = $true
            $file = New-Item -Path (Join-Path $Script:TestRoot 'move_test.txt') -ItemType File -Force
            $dst = Join-Path $Script:DestinationRoot $file.Name
            (Move-ItemSafe -Item (Get-Item $file.FullName) -TargetPath $dst) | Should -BeTrue
            (Test-Path $file.FullName) | Should -BeTrue
            Remove-Item $file -Force
        }
    }

    Context "Get-DriveFreeSpaceMB" {
        It "returns an integer free-space value for the drive containing the path" {
            $result = Get-DriveFreeSpaceMB -Path $Script:TestRoot
            if ($result -ne $null) { $result | Should -BeOfType int }
        }
    }
}

AfterAll {
    # Clean up test artifacts by removing all files (except the test script) and subdirectories in the tests directory
    if ($global:TestRoot -and (Test-Path $global:TestRoot)) {
        Get-ChildItem $global:TestRoot -File | Where-Object { $_.Name -ne 'Downloads-Auto-Archiver.Tests.ps1' } | Remove-Item -Force
        Get-ChildItem $global:TestRoot -Directory | Remove-Item -Recurse -Force
    }
}