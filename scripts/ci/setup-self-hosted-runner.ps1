<#
.SYNOPSIS
    One-shot setup of a self-hosted GitHub Actions runner. Generic template
    from dstefl/foundry — proven on dstefl/lunarpowerpulse + dstefl/energeticky-semafor.
    Consuming projects copy this file into their `scripts/` and override the
    param() defaults (RepoOwner, RepoName, RunnerLabels) for their repo.

.DESCRIPTION
    Downloads the latest runner binary, registers it against the repo with the
    caller-specified labels, installs + starts it as a Windows service, and
    (by default) flips the `USE_SELF_HOSTED` repo variable to route gated CI jobs
    to the runner.

    Idempotent: safe to re-run after a partial failure. Existing runner config /
    service is detected, stopped, and replaced cleanly.

    Must be run from an **elevated PowerShell** (Run as Administrator) -- the
    Windows-service install step requires admin rights. See
    docs/SELF_HOSTED_RUNNER.md for how to launch elevated.

    File is intentionally pure ASCII (no em-dashes, bullets, box-drawing, or
    check marks). Windows PowerShell 5.1 without a UTF-8 BOM parses non-ASCII
    bytes as ANSI/CP-1252, breaking string tokenisation. Keeping it ASCII makes
    the script portable across PS 5.1 + 7+ without an encoding dependency.

.PARAMETER RunnerDir
    Filesystem path to install the runner into. Default: D:\repos\github\a_runners.
    The directory will be created if missing. Avoid putting it inside a git repo
    (the _work subfolder grows to several GB and shouldn't be tracked).

.PARAMETER RepoOwner
    GitHub user/org owning the repo. No default — override per-project (this
    is a generic template; the consuming project edits the param() default
    OR passes the flag at invocation time).

.PARAMETER RepoName
    Repository name. No default — see RepoOwner above.

.PARAMETER RunnerLabels
    Comma-separated labels to register the runner with. Default: `windows`.
    Most projects add their own label too (e.g. `my-runner,windows`); the
    workflow files in `.github/workflows/` then `runs-on:` that label. The
    `windows` baseline lets `runs-on: windows-latest` jobs land here too.

.PARAMETER RunnerName
    Display name for the runner in GitHub UI. Default: machine hostname
    ($env:COMPUTERNAME).

.PARAMETER NoAutoToggle
    Switch. If set, skip the final step that sets `vars.USE_SELF_HOSTED=true`.
    Useful for running the script against a fresh runner and testing it ad-hoc
    before redirecting all CI to it.

.EXAMPLE
    PS> .\setup-self-hosted-runner.ps1

    Default invocation: installs runner at D:\repos\github\a_runners with the
    machine name, registers + starts as service, flips the toggle on.

.EXAMPLE
    PS> .\setup-self-hosted-runner.ps1 -RunnerDir 'D:\custom\runner' -NoAutoToggle

    Custom path; doesn't flip the workflow toggle. Use this for staging.

.EXAMPLE
    PS> Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-File',(Resolve-Path .\setup-self-hosted-runner.ps1).Path

    Launch from a non-elevated PowerShell -- pops UAC and runs the script in a
    new elevated window with -NoExit so the output stays visible.

.NOTES
    Prerequisites on the machine (consuming project may need different versions):
      * Node.js (project-specific; lunarpowerpulse pins 22)
      * Git for Windows (bundles Git Bash -- needed by workflows with `shell: bash`)
      * GitHub CLI (`gh`), authenticated against the same user

    Rollback (flip CI back to cloud):
        gh variable delete USE_SELF_HOSTED --repo $RepoOwner/$RepoName

    Full deregistration (runner v2.300+ -- svc.cmd is gone, sc.exe + config.cmd remove handle it):
        cd <RunnerDir>
        $svc = Get-Service "actions.runner.*"
        Stop-Service $svc -Force
        sc.exe delete $svc.Name
        $tok = (gh api -X POST /repos/$RepoOwner/$RepoName/actions/runners/remove-token | ConvertFrom-Json).token
        .\config.cmd remove --token $tok
#>

[CmdletBinding()]
param(
    # No good cross-project default for RunnerDir. Most setups put a_runners
    # OUTSIDE any git repo to avoid `_work` (multi-GB scratch space) being
    # tracked by the project's git accidentally.
    [string]$RunnerDir    = 'D:\repos\github\a_runners',
    [Parameter(Mandatory=$true)][string]$RepoOwner,
    [Parameter(Mandatory=$true)][string]$RepoName,
    [string]$RunnerLabels = 'windows',
    [string]$RunnerName   = $env:COMPUTERNAME,
    [switch]$NoAutoToggle
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== Self-hosted GitHub Actions runner setup ===" -ForegroundColor Cyan
Write-Host "Repository:    $RepoOwner/$RepoName"
Write-Host "Runner dir:    $RunnerDir"
Write-Host "Runner name:   $RunnerName"
Write-Host "Runner labels: $RunnerLabels"
$toggleLabel = if ($NoAutoToggle) { 'NO (manual gh variable set required)' } else { 'YES (USE_SELF_HOSTED=true after success)' }
Write-Host "Auto-toggle:   $toggleLabel"
Write-Host ""

# --- Step 0/6: prerequisites --------------------------------------------------
Write-Host "Step 0/6: checking prerequisites..." -ForegroundColor Cyan

# Admin elevation (svc.cmd install needs it)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Must run from elevated PowerShell (Run as Administrator). Service install requires admin."
}

# Required tools on PATH
$missing = @('gh','node','git') | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
if ($missing) {
    throw "Missing tools on PATH: $($missing -join ', '). Install: winget install OpenJS.NodeJS.LTS GitHub.cli Git.Git"
}

# Architecture sanity -- x64 runner won't run on ARM64
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne 'AMD64') {
    throw "Architecture is $arch but this script downloads the x64 runner. Edit if on ARM64."
}

# gh authenticated?
& gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "gh CLI is not authenticated. Run 'gh auth login' first."
}

# Parent dir of $RunnerDir must exist + be writable
$parentDir = Split-Path -Parent $RunnerDir
if (-not (Test-Path $parentDir)) {
    throw "Parent directory $parentDir doesn't exist. Create it or pick a different -RunnerDir."
}
$probe = Join-Path $parentDir ".write-probe-$([Guid]::NewGuid())"
try {
    New-Item -ItemType File -Path $probe -Force | Out-Null
    Remove-Item $probe -Force
} catch {
    throw "No write access to $parentDir. Pick a different -RunnerDir or fix folder permissions."
}

Write-Host "  [OK] Admin, tools on PATH, x86-64, gh authenticated, $parentDir writable"

# Ensure PowerShell execution policy allows the runner to dot-source the
# temp .ps1 scripts it generates for every step. Default Restricted policy
# blocks them with "running scripts is disabled on this system".
#
# Note: Runner.Worker.exe hosts PowerShell in-process via .NET and caches
# the policy at first read. For a fresh install (the common path) this is
# fine because Step 4 below installs + starts the service for the first
# time, AFTER this policy change has been written to the registry, so the
# initial worker process reads the new policy. For repairs to an existing
# install, use scripts/fix-runner-bash-path.ps1 which also restarts the
# service when policy or PATH change.
$currentPolicy = Get-ExecutionPolicy -Scope LocalMachine
if ($currentPolicy -notin @('RemoteSigned', 'Unrestricted', 'Bypass')) {
    Write-Host "  Setting LocalMachine execution policy to RemoteSigned (was '$currentPolicy')..."
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
    Write-Host "  [OK] Execution policy set"
} else {
    Write-Host "  [OK] Execution policy at LocalMachine already permissive ($currentPolicy)"
}

# --- Step 1/6: fetch token + latest runner version ----------------------------
Write-Host ""
Write-Host "Step 1/6: fetching registration token + latest runner version..." -ForegroundColor Cyan

$tokenJson = & gh api -X POST "/repos/$RepoOwner/$RepoName/actions/runners/registration-token"
if ($LASTEXITCODE -ne 0) { throw "Failed to fetch registration token from GitHub API." }
$token = ($tokenJson | ConvertFrom-Json).token
if (-not $token) { throw "Empty registration token returned." }

$relJson = & gh api /repos/actions/runner/releases/latest
if ($LASTEXITCODE -ne 0) { throw "Failed to query runner releases." }
$runnerVersion = ($relJson | ConvertFrom-Json).tag_name -replace '^v',''
$zipName       = "actions-runner-win-x64-$runnerVersion.zip"
$downloadUrl   = "https://github.com/actions/runner/releases/download/v$runnerVersion/$zipName"

Write-Host "  [OK] Token acquired (TTL ~1h)"
Write-Host "  [OK] Latest runner: v$runnerVersion"

# --- Step 2/6: prepare runner directory (idempotent) --------------------------
Write-Host ""
Write-Host "Step 2/6: preparing $RunnerDir..." -ForegroundColor Cyan

if ((Test-Path $RunnerDir) -and (Test-Path "$RunnerDir\.runner")) {
    Write-Host "  WARN: Existing runner config detected -- deregistering before reinstall..." -ForegroundColor Yellow
    Push-Location $RunnerDir
    try {
        # Stop + uninstall existing service if present
        $svc = Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($svc) {
            # Modern runner (v2.300+) doesn't bundle svc.cmd; we drive sc.exe
            # directly so cleanup works regardless of what installed the service.
            Write-Host "    Stopping + removing existing service: $($svc.Name)"
            Stop-Service $svc -Force -ErrorAction SilentlyContinue
            & sc.exe delete $svc.Name 2>&1 | Out-Null
        }
        # Deregister with GitHub
        $removeTokenJson = & gh api -X POST "/repos/$RepoOwner/$RepoName/actions/runners/remove-token"
        if ($LASTEXITCODE -eq 0) {
            $removeToken = ($removeTokenJson | ConvertFrom-Json).token
            & .\config.cmd remove --token $removeToken 2>&1 | Out-Null
            $removeToken = $null
        }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $RunnerDir)) {
    New-Item -ItemType Directory -Path $RunnerDir -Force | Out-Null
}
Write-Host "  [OK] Directory ready"

# --- Step 3/6: download + extract ---------------------------------------------
Push-Location $RunnerDir
try {
    Write-Host ""
    Write-Host "Step 3/6: downloading runner..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipName -TimeoutSec 300 -UseBasicParsing
    Write-Host "  [OK] Downloaded $zipName"

    Write-Host "Step 3/6: extracting..." -ForegroundColor Cyan
    Expand-Archive -Path $zipName -DestinationPath $RunnerDir -Force
    Remove-Item $zipName
    Write-Host "  [OK] Extracted"

    # --- Step 4/6: configure runner + install service in one call ------------
    # Modern runner (v2.300+) consolidates "configure" and "install as service"
    # into a single config.cmd call via the --runasservice flag. The older
    # separate svc.cmd install/start pattern is gone in v2.334+. --runasservice
    # registers + starts the Windows service using NT AUTHORITY\NETWORK SERVICE
    # by default (override via --windowslogonaccount / --windowslogonpassword).
    Write-Host ""
    Write-Host "Step 4/6: configuring runner + installing service..." -ForegroundColor Cyan
    & .\config.cmd --unattended `
        --url "https://github.com/$RepoOwner/$RepoName" `
        --token $token `
        --name $RunnerName `
        --labels $RunnerLabels `
        --work _work `
        --replace `
        --runasservice
    if ($LASTEXITCODE -ne 0) { throw "config.cmd failed (exit $LASTEXITCODE)" }
    $token = $null  # clear from memory immediately after use
    Write-Host "  [OK] Registered as '$RunnerName' (labels: $RunnerLabels)"

    # --- Step 5/6: verify service Running + Git Bash on PATH ------------------
    # Two pieces: (a) confirm the Windows service reached Running locally,
    # (b) make sure `shell: bash` in workflows resolves to Git Bash, not WSL.
    #
    # The bash-on-PATH check is here (not earlier) because we want to restart
    # the runner service AFTER fixing PATH so the service inherits the new env.
    # On a fresh Windows machine, `bash` typically resolves to
    # C:\WINDOWS\system32\bash.EXE (WSL launcher), and if WSL has no distro
    # installed every `shell: bash` workflow step fails with
    # WSL_E_DEFAULT_DISTRO_NOT_FOUND. Putting Git Bash ahead of system32 on
    # the MACHINE PATH (admin-only) fixes it for the service's environment.
    #
    # Same logic also lives in scripts/fix-runner-bash-path.ps1 for repairing
    # machines that were set up before this guard was baked in. Keep in sync.
    Write-Host ""
    Write-Host "Step 5/6: verifying service + ensuring Git Bash on PATH..." -ForegroundColor Cyan
    Start-Sleep -Seconds 3
    $svc = Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $svc) {
        throw "No actions.runner.* service found after --runasservice. Check config.cmd output."
    }
    if ($svc.Status -ne 'Running') {
        Write-Host "  Service exists but not yet Running -- starting..."
        Start-Service $svc
        Start-Sleep -Seconds 3
        $svc.Refresh()
        if ($svc.Status -ne 'Running') {
            throw "Service '$($svc.Name)' didn't reach Running state. Check Event Viewer or services.msc."
        }
    }
    Write-Host "  [OK] Service '$($svc.Name)' is Running"

    # Locate Git Bash via the git.exe on PATH (portable across install dirs)
    $gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source
    if ($gitExe) {
        $gitInstallRoot = Split-Path -Parent (Split-Path -Parent $gitExe)
        $gitBashDir = Join-Path $gitInstallRoot 'bin'
        $gitBashExe = Join-Path $gitBashDir 'bash.exe'
        if (Test-Path $gitBashExe) {
            $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
            $pathEntries = @($machinePath -split ';' | Where-Object { $_ })
            $normalizedGitBashDir = $gitBashDir.TrimEnd('\').ToLower()
            $gitBashIdx = -1
            $system32Idx = -1
            for ($i = 0; $i -lt $pathEntries.Count; $i++) {
                $entry = $pathEntries[$i].TrimEnd('\').ToLower()
                if ($entry -eq $normalizedGitBashDir) { $gitBashIdx = $i }
                if ($entry -eq 'c:\windows\system32') { $system32Idx = $i }
            }
            if ($gitBashIdx -ge 0 -and ($system32Idx -lt 0 -or $gitBashIdx -lt $system32Idx)) {
                Write-Host "  [OK] Git Bash already on machine PATH ahead of system32"
            } else {
                if ($gitBashIdx -ge 0) {
                    $pathEntries = @($pathEntries | Where-Object { $_.TrimEnd('\').ToLower() -ne $normalizedGitBashDir })
                }
                $newPath = (@($gitBashDir) + $pathEntries) -join ';'
                [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
                Write-Host "  [OK] Prepended $gitBashDir to machine PATH"
                Write-Host "  Restarting service so it picks up the new PATH..."
                Restart-Service $svc -Force
                Start-Sleep -Seconds 3
                $svc.Refresh()
                if ($svc.Status -ne 'Running') {
                    throw "Service didn't restart cleanly after PATH update. Status: $($svc.Status)."
                }
                Write-Host "  [OK] Service restarted, status: Running"
            }
        } else {
            Write-Host "  WARN: git.exe on PATH but Git Bash not found at $gitBashExe -- workflows using shell:bash may fail." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  WARN: git.exe not on PATH -- workflows using shell:bash will fail." -ForegroundColor Yellow
    }

    # Wait for GitHub to mark it Online (server-side check, after any restart)
    Write-Host "  Waiting ~10 s for GitHub to register the runner as Online..."
    Start-Sleep -Seconds 10
    $runnersJson = & gh api "/repos/$RepoOwner/$RepoName/actions/runners"
    if ($LASTEXITCODE -eq 0) {
        $online = ($runnersJson | ConvertFrom-Json).runners |
                  Where-Object { $_.name -eq $RunnerName -and $_.status -eq 'online' }
        if ($online) {
            Write-Host "  [OK] GitHub reports runner '$RunnerName' as Online"
        } else {
            Write-Host "  WARN: GitHub didn't report runner as Online within 10 s. Service is Running locally; verify via UI." -ForegroundColor Yellow
            Write-Host "    https://github.com/$RepoOwner/$RepoName/settings/actions/runners" -ForegroundColor Yellow
        }
    }
} finally {
    Pop-Location
}

# --- Step 6/6: enable workflow toggle (LAST -- after runner verified) ---------
Write-Host ""
if ($NoAutoToggle) {
    Write-Host "Step 6/6: SKIPPING toggle (per -NoAutoToggle). Workflows still go to cloud." -ForegroundColor Yellow
    Write-Host "  To enable manually after testing:"
    Write-Host "    gh variable set USE_SELF_HOSTED --body 'true' --repo $RepoOwner/$RepoName"
} else {
    Write-Host "Step 6/6: flipping USE_SELF_HOSTED=true repo variable..." -ForegroundColor Cyan
    & gh variable set USE_SELF_HOSTED --body 'true' --repo "$RepoOwner/$RepoName"
    if ($LASTEXITCODE -ne 0) { throw "gh variable set failed (exit $LASTEXITCODE)" }
    Write-Host "  [OK] vars.USE_SELF_HOSTED = true"
}

# --- Summary ------------------------------------------------------------------
Write-Host ""
Write-Host "=== Setup complete! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Runner: '$RunnerName' (label: lunar-runner)"
if ($svc) { Write-Host "Service: $($svc.Name) (Running, autostart on boot)" }
Write-Host ""
Write-Host "Verify:"
Write-Host "  https://github.com/$RepoOwner/$RepoName/settings/actions/runners"
Write-Host ""
Write-Host "Test by triggering health-monitor:"
Write-Host "  gh workflow run health-monitor.yml --repo $RepoOwner/$RepoName"
Write-Host "  gh run watch --repo $RepoOwner/$RepoName"
Write-Host ""
Write-Host "Rollback to cloud-only:"
Write-Host "  gh variable delete USE_SELF_HOSTED --repo $RepoOwner/$RepoName"
Write-Host ""
Write-Host "Full deregistration: see scripts/setup-self-hosted-runner.ps1 .NOTES"
