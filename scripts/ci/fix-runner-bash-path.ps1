<#
.SYNOPSIS
    Fixes a self-hosted runner so `shell: bash` resolves to Git Bash, not WSL.

.DESCRIPTION
    On Windows runners, GitHub Actions resolves `shell: bash` in workflows via
    PATH lookup of `bash.exe`. By default `C:\WINDOWS\system32\bash.EXE` (the
    WSL launcher) wins. If WSL has no distribution installed, every bash step
    fails with WSL_E_DEFAULT_DISTRO_NOT_FOUND.

    This script prepends the Git Bash bin directory to the MACHINE PATH so
    bash resolves to Git Bash. Then it restarts the runner service so the new
    PATH takes effect for subsequent jobs. Idempotent -- safe to re-run.

    Auto-detects:
      * Git Bash location (walks up from `git.exe` on PATH to find `<install>\bin\bash.exe`)
      * Runner service name (Get-Service "actions.runner.*")

    Must run from an elevated PowerShell (writing machine PATH requires admin).

.PARAMETER ServiceName
    Override the auto-detected runner service name. Useful if multiple runners
    are registered on the machine.

.EXAMPLE
    PS> .\fix-runner-bash-path.ps1

    Auto-detects Git Bash + runner service, prepends Git Bash to PATH if
    needed, restarts the service so it picks up the new PATH.

.NOTES
    The fix is also baked into scripts/setup-self-hosted-runner.ps1 so fresh
    installs after the fix landed are correct out-of-the-box. This script is
    for machines that ran the older installer and need an in-place fix without
    reinstalling the runner.

    Pure ASCII (no em-dashes / bullets / box-drawing) -- PowerShell 5.1 without
    a UTF-8 BOM parses non-ASCII as ANSI/CP-1252 and breaks tokenisation.
#>

[CmdletBinding()]
param(
    [string]$ServiceName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== Fix runner shell:bash resolution + PowerShell execution policy ===" -ForegroundColor Cyan
Write-Host ""

# --- Admin check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Must run from elevated PowerShell. Writing machine PATH + LocalMachine policy requires admin."
}

# --- PowerShell execution policy (LocalMachine scope) ---
# GitHub Actions runner on Windows generates temp .ps1 scripts in _work\_temp
# for every run step and dot-sources them. Default Windows execution policy
# is Restricted (or Undefined falling through to Restricted), which blocks
# those temp scripts with "running scripts is disabled on this system".
# RemoteSigned allows local + signed-remote scripts -- safe for a CI runner.
#
# IMPORTANT: even though PowerShell reads execution policy from the registry
# fresh on each invocation, the runner's worker process (Runner.Worker.exe)
# hosts PowerShell in-process via .NET and caches the policy at first read.
# A service restart is required for the new policy to actually apply to
# subsequent workflow steps. We track $policyChanged so a single restart at
# the end of this script covers both PATH and policy changes.
$policyChanged = $false
$currentPolicy = Get-ExecutionPolicy -Scope LocalMachine
if ($currentPolicy -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
    Write-Host "  [OK] PowerShell execution policy already permissive at LocalMachine ($currentPolicy)"
} else {
    Write-Host "  PowerShell execution policy at LocalMachine is '$currentPolicy' -- workflows will fail."
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
    Write-Host "  [OK] Set execution policy to RemoteSigned at LocalMachine"
    $policyChanged = $true
}

# --- Find Git Bash ---
# Locate git.exe on PATH, walk up to install root, find bash.exe in `bin\`.
# Portable across different Git install locations (no hard-coded paths).
$gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $gitExe) {
    throw "git.exe not on PATH. Install Git for Windows: winget install Git.Git"
}
# git.exe is at <install>\cmd\git.exe; we want <install>\bin\ (which holds bash.exe)
$gitInstallRoot = Split-Path -Parent (Split-Path -Parent $gitExe)
$gitBashDir = Join-Path $gitInstallRoot 'bin'
$gitBashExe = Join-Path $gitBashDir 'bash.exe'

if (-not (Test-Path $gitBashExe)) {
    throw "Git Bash not found at $gitBashExe. Reinstall Git for Windows with default options."
}
Write-Host "  [OK] Git Bash found at: $gitBashExe"

# --- Check + fix machine PATH ---
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$pathEntries = @($machinePath -split ';' | Where-Object { $_ })

$gitBashIdx = -1
$system32Idx = -1
$normalizedGitBashDir = $gitBashDir.TrimEnd('\').ToLower()
for ($i = 0; $i -lt $pathEntries.Count; $i++) {
    $entry = $pathEntries[$i].TrimEnd('\').ToLower()
    if ($entry -eq $normalizedGitBashDir) { $gitBashIdx = $i }
    if ($entry -eq 'c:\windows\system32') { $system32Idx = $i }
}

$pathChanged = $false
if ($gitBashIdx -ge 0 -and ($system32Idx -lt 0 -or $gitBashIdx -lt $system32Idx)) {
    Write-Host "  [OK] $gitBashDir already on machine PATH ahead of system32. No change needed."
} else {
    # Remove existing Git Bash entry if present (it's after system32 or missing)
    if ($gitBashIdx -ge 0) {
        Write-Host "  Git Bash currently at PATH position $gitBashIdx (system32 at $system32Idx). Moving to front..."
        $pathEntries = @($pathEntries | Where-Object { $_.TrimEnd('\').ToLower() -ne $normalizedGitBashDir })
    } else {
        Write-Host "  Git Bash not on machine PATH. Prepending $gitBashDir..."
    }
    $newPath = (@($gitBashDir) + $pathEntries) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
    Write-Host "  [OK] Updated machine PATH (Git Bash now first)"
    $pathChanged = $true
}

# --- Restart runner service so it inherits the new PATH ---
if (-not $ServiceName) {
    $svc = Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $svc) {
        Write-Host ""
        Write-Host "  WARN: No actions.runner.* service found on this machine." -ForegroundColor Yellow
        Write-Host "        PATH change still applies; future shells will see Git Bash first."
        Write-Host "        Skipping service restart."
        return
    }
    $ServiceName = $svc.Name
}

if ($pathChanged -or $policyChanged) {
    Write-Host ""
    $reason = @()
    if ($pathChanged) { $reason += 'PATH change' }
    if ($policyChanged) { $reason += 'execution-policy change' }
    Write-Host "  Restarting service '$ServiceName' to pick up $(($reason -join ' + '))..."
    Restart-Service $ServiceName -Force
    Start-Sleep -Seconds 3
    $svc = Get-Service $ServiceName
    if ($svc.Status -ne 'Running') {
        throw "Service '$ServiceName' didn't restart cleanly. Status: $($svc.Status). Check services.msc / Event Viewer."
    }
    Write-Host "  [OK] Service '$ServiceName' restarted, status: Running"
} else {
    Write-Host "  Service '$ServiceName' restart skipped (nothing changed)."
}

# --- Summary ---
Write-Host ""
Write-Host "=== Fix complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Subsequent runner jobs that use 'shell: bash' will resolve to Git Bash."
Write-Host ""
Write-Host "Verify by re-triggering a workflow that uses bash:"
Write-Host "  gh workflow run health-monitor.yml --repo dstefl/lunarpowerpulse"
Write-Host "  gh run watch --repo dstefl/lunarpowerpulse"
