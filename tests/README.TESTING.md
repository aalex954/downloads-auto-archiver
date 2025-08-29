# Downloads Auto-Archiver — Testing Guide

What this includes
- A Pester test script: ./tests/Downloads-Auto-Archiver.Tests.ps1
- Tests exercise each function (non-destructively when possible).

Prerequisites
- PowerShell (Windows PowerShell 5.1 or PowerShell 7+)
- Pester (recommended v4 or v5)
  - Install (if needed): Install-Module -Name Pester -Scope CurrentUser -Force

Running the tests
1. Open PowerShell.
2. Change to the project root:
   cd "c:\Users\alexf\Source\downloads-auto-archiver"
3. Run the tests:
   - With Pester v5: Invoke-Pester -Script .\tests\Downloads-Auto-Archiver.Tests.ps1
   - With older Pester: .\tests\Downloads-Auto-Archiver.Tests.ps1 (or Invoke-Pester)
4. Tests create temporary files/folders under your system TEMP folder and clean them up.

Interpreting results
- Green / Passed: the function behaved as expected.
- Red / Failed: examine the failing It block output for details. The tests are designed to be safe (most operations run with DryRun enabled).
- The test for Write-LogEntry writes logs under a temporary LocalLogDir (printed in the test harness output on failure). If a log file exists, you can inspect:
  - DownloadsAutoArchiver.log.jsonl (JSON Lines)
  - DownloadsAutoArchiver.log.csv  (CSV summary)

Safety notes
- Tests default to setting the script's DryRun flag and avoid running destructive code paths where possible.
- If you change tests to disable DryRun, run them only in an isolated environment.

Extending tests
- Add additional It blocks to tests/Downloads-Auto-Archiver.Tests.ps1.
- For testing Robocopy behavior, mock Start-Process or run in an environment where Robocopy presence and target shares are controlled.

