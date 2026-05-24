<#
.SYNOPSIS
    One-shot setup of one or more self-hosted GitHub Actions runners on a
    Windows host. Generic foundry template — proven across
    dstefl/lunarpowerpulse, dstefl/energeticky-semafor, dstefl/householdsim.

.DESCRIPTION
    Downloads the latest runner binary, registers it against the repo with the
    caller-specified labels, installs + starts it as a Windows service, and
    (by default) flips the `USE_SELF_HOSTED` repo variable so gated workflow
    jobs route to the runner.

    Multi-runner mode (`-Count N`, N >= 2) installs N parallel runners in
    numbered sibling directories under `-RunnerRoot`. All N share the same
    label, so GitHub dispatches the next queued workflow run to whichever
    runner is idle. Two simultaneous pushes execute in parallel instead of
    queueing.

    Performance tweaks baked in:
      * Shared pnpm store under `$RunnerRoot\pnpm-store` (env var
        PNPM_STORE_PATH at machine scope). All runners hard-link from one
        content-addressable store on install.
      * Shared Playwright browsers cache under `$RunnerRoot\playwright-browsers`
        (env var PLAYWRIGHT_BROWSERS_PATH at machine scope). Saves the
        ~150 MB Chromium download per runner per workflow.
      * --runasservice so the runner starts at boot.

    Workflow-side gotcha (REQUIRED for multi-runner mode on the same Windows
    host): scope pnpm/action-setup's install dir to runner.temp. Without this,
    multiple runners share NETWORK SERVICE's home directory and race on the
    rmdir/extract step. In your .github/workflows/*.yml:

        - name: Setup pnpm
          uses: pnpm/action-setup@v4
          with:
            dest: ${{ runner.temp }}/setup-pnpm

    See README.md for the full list of workflow-side requirements.

    Idempotent: safe to re-run after a partial failure. Existing runner config /
    service is detected, stopped, and replaced cleanly per slot.

    Must be run from an elevated PowerShell (Run as Administrator) -- the
    Windows-service install step requires admin rights. Launch via:
        Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-File',(Resolve-Path .\setup-self-hosted-runner.ps1).Path

    File is intentionally pure ASCII (no em-dashes, bullets, box-drawing, or
    check marks). Windows PowerShell 5.1 without a UTF-8 BOM parses non-ASCII
    bytes as ANSI/CP-1252, breaking string tokenisation.

.PARAMETER RunnerRoot
    Parent directory under which each runner gets its own subfolder. Default:
    D:\repos\github\a_runners. With `-Count 1` (default) the runner installs
    directly here; with `-Count >= 2` runners install into `$RunnerRoot\1`,
    `$RunnerRoot\2`, ... so they don't collide on `_work`, `.runner`, or the
    service name.

    Place this OUTSIDE any git repo — `_work` grows to several GB and
    shouldn't be tracked.

.PARAMETER RepoOwner
    GitHub user/org owning the repo. Mandatory.

.PARAMETER RepoName
    Repository name. Mandatory.

.PARAMETER RunnerLabels
    Comma-separated labels to register every runner with. Default: `windows`.
    Most projects add their own (e.g. `my-runner,windows`); the workflow's
    `runs-on:` then routes to that custom label.

.PARAMETER RunnerNamePrefix
    Prefix for the GitHub-visible runner name. Default: `$env:COMPUTERNAME`.
    Single-runner mode uses the prefix as-is. With `-Count >= 2`, each runner
    appends `-1`, `-2`, ... so names stay unique. Coexisting installs on the
    same machine (e.g. one runner per repo) should use a project suffix in
    the prefix to avoid GitHub-side name collisions when the prefix happens
    to match across projects.

.PARAMETER Count
    How many runners to install. Default: 1. Sensible values 1-4 on a typical
    developer machine; 6+ on a dedicated build host. Each runner is ~150 MB
    idle, ~2 GB during an active Node + Playwright workflow. Shared caches
    keep disk cost sublinear.

.PARAMETER NoAutoToggle
    Switch. Skip the final `gh variable set USE_SELF_HOSTED true` step. Use to
    stage the install (verify runners come up Online) before redirecting CI.

.EXAMPLE
    PS> .\setup-self-hosted-runner.ps1 -RepoOwner dstefl -RepoName my-project -RunnerLabels 'my-project-runner,windows'

    Single runner under D:\repos\github\a_runners, named `<HOSTNAME>`,
    `USE_SELF_HOSTED=true` flipped at the end.

.EXAMPLE
    PS> .\setup-self-hosted-runner.ps1 -RepoOwner dstefl -RepoName my-project -RunnerLabels 'my-project-runner,windows' -Count 4 -RunnerNamePrefix "$env:COMPUTERNAME-myproj"

    Four parallel runners under `\1` .. `\4`, names `<HOSTNAME>-myproj-1` ..
    `-4`. Concurrent jobs run side-by-side. Use the `-myproj` suffix to keep
    names distinct from runners belonging to other repos on the same host.

.EXAMPLE
    PS> .\setup-self-hosted-runner.ps1 -RepoOwner dstefl -RepoName my-project -RunnerLabels 'my-project-runner,windows' -NoAutoToggle

    Install + verify but don't flip the workflow toggle. CI stays on
    GitHub-hosted until you run:
        gh variable set USE_SELF_HOSTED --body true --repo dstefl/my-project

.NOTES
    Prerequisites on the machine (consuming project may need additional/
    specific versions):
      * Node.js (project-specific; check the workflow's actions/setup-node)
      * pnpm via corepack — `corepack enable; corepack prepare pnpm@latest --activate`
      * Git for Windows (bundles Git Bash — needed by workflows with `shell: bash`)
      * GitHub CLI (`gh`), authenticated against the repo owner

    Rollback (CI back to GitHub-hosted):
        gh variable delete USE_SELF_HOSTED --repo $RepoOwner/$RepoName

    Deregister a slot:
        cd <RunnerRoot or RunnerRoot\N>
        $svc = Get-Service "actions.runner.*" | Where-Object {
            $_.Name -like "*$($env:COMPUTERNAME)*"
        }
        Stop-Service $svc -Force; sc.exe delete $svc.Name
        $tok = (gh api -X POST /repos/$RepoOwner/$RepoName/actions/runners/remove-token | ConvertFrom-Json).token
        .\config.cmd remove --token $tok

    Coexistence with other runner installs on the same host: each install
    lives in its own folder and its own Windows service (named by
    `actions.runner.<owner>-<repo>.<runnerName>`). They don't interfere.
#>

[CmdletBinding()]
param(
    [string]$RunnerRoot       = 'D:\repos\github\a_runners',
    [Parameter(Mandatory=$true)][string]$RepoOwner,
    [Parameter(Mandatory=$true)][string]$RepoName,
    [string]$RunnerLabels     = 'windows',
    [string]$RunnerNamePrefix = $env:COMPUTERNAME,
    [int]$Count               = 1,
    [switch]$NoAutoToggle
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Count -lt 1) { throw "-Count must be >= 1 (got $Count)" }
if ($Count -gt 8) { Write-Host "WARN: -Count $Count is unusually high; runners are 150 MB idle each, 2 GB active." -ForegroundColor Yellow }

Write-Host "=== Self-hosted runner setup ===" -ForegroundColor Cyan
Write-Host "Repository:       $RepoOwner/$RepoName"
Write-Host "Runner root:      $RunnerRoot"
Write-Host "Runner prefix:    $RunnerNamePrefix"
Write-Host "Runner labels:    $RunnerLabels"
Write-Host "Runner count:     $Count"
$toggleLabel = if ($NoAutoToggle) { 'NO (manual gh variable set required)' } else { 'YES (USE_SELF_HOSTED=true after success)' }
Write-Host "Auto-toggle:      $toggleLabel"
Write-Host ""

# --- Step 0: prerequisites ----------------------------------------------------
Write-Host "Step 0: checking prerequisites..." -ForegroundColor Cyan

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Must run from elevated PowerShell (Run as Administrator). Service install requires admin."
}

$missing = @('gh','node','git') | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
if ($missing) {
    throw "Missing tools on PATH: $($missing -join ', '). Install: winget install OpenJS.NodeJS.LTS GitHub.cli Git.Git"
}

$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne 'AMD64') {
    throw "Architecture is $arch but this script downloads the x64 runner. Edit if on ARM64."
}

& gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "gh CLI is not authenticated. Run 'gh auth login' first."
}

$parentDir = Split-Path -Parent $RunnerRoot
if (-not (Test-Path $parentDir)) {
    throw "Parent directory $parentDir doesn't exist. Create it or pick a different -RunnerRoot."
}
$probe = Join-Path $parentDir ".write-probe-$([Guid]::NewGuid())"
try {
    New-Item -ItemType File -Path $probe -Force | Out-Null
    Remove-Item $probe -Force
} catch {
    throw "No write access to $parentDir. Pick a different -RunnerRoot or fix folder permissions."
}

Write-Host "  [OK] Admin, tools on PATH, x86-64, gh authenticated, $parentDir writable"

$currentPolicy = Get-ExecutionPolicy -Scope LocalMachine
if ($currentPolicy -notin @('RemoteSigned', 'Unrestricted', 'Bypass')) {
    Write-Host "  Setting LocalMachine execution policy to RemoteSigned (was '$currentPolicy')..."
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
    Write-Host "  [OK] Execution policy set"
} else {
    Write-Host "  [OK] Execution policy at LocalMachine already permissive ($currentPolicy)"
}

# --- Step 1: shared cache directories (performance) ---------------------------
# These live ONE level up from the per-runner folders, so all runners share.
# pnpm uses a content-addressable store: hard-linking from a shared store is
# free disk-space-wise and saves the 30-60 s install per runner per workflow.
# PLAYWRIGHT_BROWSERS_PATH = deterministic shared dir so `playwright install`
# is a no-op on the 2nd+ runner after the first populates it.
Write-Host ""
Write-Host "Step 1: provisioning shared caches under $RunnerRoot..." -ForegroundColor Cyan

if (-not (Test-Path $RunnerRoot)) {
    New-Item -ItemType Directory -Path $RunnerRoot -Force | Out-Null
}
$pnpmStorePath          = Join-Path $RunnerRoot 'pnpm-store'
$playwrightBrowsersPath = Join-Path $RunnerRoot 'playwright-browsers'
foreach ($d in @($pnpmStorePath, $playwrightBrowsersPath)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Host "  [OK] Created $d"
    } else {
        Write-Host "  [OK] Exists $d"
    }
}

# MACHINE-level env vars so the runner service (NT AUTHORITY\NETWORK SERVICE)
# inherits them. User-level env doesn't propagate to service principals.
$envVars = @{
    'PNPM_STORE_PATH'          = $pnpmStorePath
    'PLAYWRIGHT_BROWSERS_PATH' = $playwrightBrowsersPath
}
foreach ($k in $envVars.Keys) {
    $currentVal = [Environment]::GetEnvironmentVariable($k, 'Machine')
    if ($currentVal -ne $envVars[$k]) {
        [Environment]::SetEnvironmentVariable($k, $envVars[$k], 'Machine')
        Write-Host "  [OK] Set MACHINE env $k = $($envVars[$k])"
    } else {
        Write-Host "  [OK] MACHINE env $k already correct"
    }
}

# --- Step 2: latest runner version + cached download --------------------------
Write-Host ""
Write-Host "Step 2: fetching latest runner version..." -ForegroundColor Cyan

$relJson = & gh api repos/actions/runner/releases/latest
if ($LASTEXITCODE -ne 0) { throw "Failed to query runner releases." }
$runnerVersion = ($relJson | ConvertFrom-Json).tag_name -replace '^v',''
$zipName       = "actions-runner-win-x64-$runnerVersion.zip"
$downloadUrl   = "https://github.com/actions/runner/releases/download/v$runnerVersion/$zipName"

Write-Host "  [OK] Latest runner: v$runnerVersion"

$sharedZip = Join-Path $RunnerRoot $zipName
if (-not (Test-Path $sharedZip)) {
    Write-Host "  Downloading $zipName ..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $sharedZip -TimeoutSec 300 -UseBasicParsing
    Write-Host "  [OK] Downloaded to $sharedZip"
} else {
    Write-Host "  [OK] Reusing cached $sharedZip"
}

# --- Step 3: per-runner install loop -----------------------------------------
$installedSlots = @()

for ($slot = 1; $slot -le $Count; $slot++) {
    Write-Host ""
    Write-Host "=== Slot $slot/$Count ===" -ForegroundColor Cyan

    if ($Count -eq 1) {
        $slotDir = $RunnerRoot
        $slotName = $RunnerNamePrefix
    } else {
        $slotDir = Join-Path $RunnerRoot $slot
        $slotName = "$RunnerNamePrefix-$slot"
    }

    Write-Host "Slot dir:  $slotDir"
    Write-Host "Slot name: $slotName"

    # Fresh registration token per slot (TTL ~1h, single-use).
    $tokenJson = & gh api -X POST "repos/$RepoOwner/$RepoName/actions/runners/registration-token"
    if ($LASTEXITCODE -ne 0) { throw "Failed to fetch registration token for slot $slot." }
    $token = ($tokenJson | ConvertFrom-Json).token
    if (-not $token) { throw "Empty registration token for slot $slot." }

    # Idempotent: tear down an existing install in this slot dir. Detect the
    # service by reading the deterministic name from <slotDir>\.service rather
    # than filtering Get-Service results on PathName (PathName lives on
    # Win32_Service / CIM, not on ServiceController — accessing it under
    # StrictMode is a hard error).
    if ((Test-Path $slotDir) -and (Test-Path "$slotDir\.runner")) {
        Write-Host "  WARN: existing config in $slotDir -- deregistering first..." -ForegroundColor Yellow
        Push-Location $slotDir
        try {
            $existingSvc = $null
            $svcFile = Join-Path $slotDir '.service'
            if (Test-Path $svcFile) {
                $svcName = (Get-Content $svcFile -Raw).Trim()
                $existingSvc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            }
            if (-not $existingSvc) {
                $deterministicName = "actions.runner.$RepoOwner-$RepoName.$slotName"
                $existingSvc = Get-Service -Name $deterministicName -ErrorAction SilentlyContinue
            }
            if ($existingSvc) {
                Write-Host "    Stopping + removing $($existingSvc.Name)"
                Stop-Service $existingSvc -Force -ErrorAction SilentlyContinue
                & sc.exe delete $existingSvc.Name 2>&1 | Out-Null
            }
            $removeTokenJson = & gh api -X POST "repos/$RepoOwner/$RepoName/actions/runners/remove-token"
            if ($LASTEXITCODE -eq 0) {
                $removeToken = ($removeTokenJson | ConvertFrom-Json).token
                & .\config.cmd remove --token $removeToken 2>&1 | Out-Null
                $removeToken = $null
            }
        } finally {
            Pop-Location
        }
    }

    if (-not (Test-Path $slotDir)) {
        New-Item -ItemType Directory -Path $slotDir -Force | Out-Null
    }

    if (-not (Test-Path "$slotDir\config.cmd")) {
        Write-Host "  Extracting runner binary..."
        Expand-Archive -Path $sharedZip -DestinationPath $slotDir -Force
        Write-Host "  [OK] Extracted to $slotDir"
    } else {
        Write-Host "  [OK] Runner binary already present"
    }

    # config.cmd --runasservice registers + installs the Windows service in
    # one shot. --replace is safe (overwrites a same-named registration on the
    # server side).
    Push-Location $slotDir
    try {
        Write-Host "  Registering + installing as service..."
        & .\config.cmd --unattended `
            --url "https://github.com/$RepoOwner/$RepoName" `
            --token $token `
            --name $slotName `
            --labels $RunnerLabels `
            --work _work `
            --replace `
            --runasservice
        if ($LASTEXITCODE -ne 0) { throw "config.cmd failed for slot $slot (exit $LASTEXITCODE)" }
        $token = $null
        Write-Host "  [OK] Registered as '$slotName' (labels: $RunnerLabels)"

        # Locate the service via .service file (preferred) or deterministic name.
        Start-Sleep -Seconds 3
        $svc = $null
        $svcFile = Join-Path $slotDir '.service'
        if (Test-Path $svcFile) {
            $svcName = (Get-Content $svcFile -Raw).Trim()
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        }
        if (-not $svc) {
            $deterministicName = "actions.runner.$RepoOwner-$RepoName.$slotName"
            $svc = Get-Service -Name $deterministicName -ErrorAction SilentlyContinue
        }
        if (-not $svc) {
            throw "No actions.runner.* service found for slot $slot after --runasservice."
        }
        if ($svc.Status -ne 'Running') {
            Write-Host "  Service exists but not Running -- starting..."
            Start-Service $svc
            Start-Sleep -Seconds 3
            $svc.Refresh()
            if ($svc.Status -ne 'Running') {
                throw "Service '$($svc.Name)' didn't reach Running. Check Event Viewer."
            }
        }
        Write-Host "  [OK] Service '$($svc.Name)' is Running"
        $installedSlots += [pscustomobject]@{ Slot = $slot; Name = $slotName; Dir = $slotDir; Service = $svc.Name }
    } finally {
        Pop-Location
    }
}

# --- Step 4: ensure Git Bash on PATH ahead of system32 -----------------------
# Done ONCE for the machine after all slots are installed. Restart all newly-
# created services so they pick up the new PATH + the cache env vars (which
# only propagate to a fresh service process).
Write-Host ""
Write-Host "Step 4: ensuring Git Bash on machine PATH..." -ForegroundColor Cyan

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
            Write-Host "  [OK] Git Bash already ahead of system32 on machine PATH"
        } else {
            if ($gitBashIdx -ge 0) {
                $pathEntries = @($pathEntries | Where-Object { $_.TrimEnd('\').ToLower() -ne $normalizedGitBashDir })
            }
            $newPath = (@($gitBashDir) + $pathEntries) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
            Write-Host "  [OK] Prepended $gitBashDir to machine PATH"
        }
    } else {
        Write-Host "  WARN: git.exe on PATH but Git Bash not found at $gitBashExe" -ForegroundColor Yellow
    }
} else {
    Write-Host "  WARN: git.exe not on PATH -- workflows using shell:bash will fail." -ForegroundColor Yellow
}

Write-Host "  Restarting installed services to pick up PATH + cache env..."
foreach ($s in $installedSlots) {
    $svc = Get-Service -Name $s.Service -ErrorAction SilentlyContinue
    if ($svc) {
        Restart-Service $svc -Force
        Start-Sleep -Seconds 2
        $svc.Refresh()
        if ($svc.Status -ne 'Running') {
            throw "Service '$($s.Service)' didn't restart cleanly. Status: $($svc.Status)."
        }
        Write-Host "    [OK] $($s.Service) -> Running"
    }
}

# --- Step 5: wait for GitHub to mark every runner Online ----------------------
Write-Host ""
Write-Host "Step 5: confirming Online status with GitHub..." -ForegroundColor Cyan
Start-Sleep -Seconds 5
$runnersJson = & gh api "repos/$RepoOwner/$RepoName/actions/runners"
if ($LASTEXITCODE -eq 0) {
    $registered = ($runnersJson | ConvertFrom-Json).runners
    foreach ($s in $installedSlots) {
        $r = $registered | Where-Object { $_.name -eq $s.Name } | Select-Object -First 1
        if ($r -and $r.status -eq 'online') {
            Write-Host "  [OK] '$($s.Name)' is Online"
        } elseif ($r) {
            Write-Host "  WARN: '$($s.Name)' registered but status=$($r.status). Verify via UI." -ForegroundColor Yellow
        } else {
            Write-Host "  WARN: '$($s.Name)' not yet visible. Wait + check https://github.com/$RepoOwner/$RepoName/settings/actions/runners" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  WARN: couldn't query runners API. Check the UI directly." -ForegroundColor Yellow
}

# --- Step 6: enable workflow toggle (last — after runners verified) ----------
Write-Host ""
if ($NoAutoToggle) {
    Write-Host "Step 6: SKIPPING toggle (per -NoAutoToggle). Workflows still go to ubuntu-latest." -ForegroundColor Yellow
    Write-Host "  To enable manually after testing:"
    Write-Host "    gh variable set USE_SELF_HOSTED --body 'true' --repo $RepoOwner/$RepoName"
} else {
    Write-Host "Step 6: flipping USE_SELF_HOSTED=true repo variable..." -ForegroundColor Cyan
    & gh variable set USE_SELF_HOSTED --body 'true' --repo "$RepoOwner/$RepoName"
    if ($LASTEXITCODE -ne 0) { throw "gh variable set failed (exit $LASTEXITCODE)" }
    Write-Host "  [OK] vars.USE_SELF_HOSTED = true"
}

# --- Summary ------------------------------------------------------------------
Write-Host ""
Write-Host "=== Setup complete! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Runners installed:"
foreach ($s in $installedSlots) {
    Write-Host ("  - {0,-22}  service:{1,-40}  dir:{2}" -f $s.Name, $s.Service, $s.Dir)
}
Write-Host ""
Write-Host "Shared caches (set as MACHINE env vars):"
Write-Host "  PNPM_STORE_PATH          = $pnpmStorePath"
Write-Host "  PLAYWRIGHT_BROWSERS_PATH = $playwrightBrowsersPath"
Write-Host ""
Write-Host "REMINDER for multi-runner mode (Count >= 2): update each workflow's"
Write-Host "Setup pnpm step to scope dest to runner.temp, e.g.:"
Write-Host "  - uses: pnpm/action-setup@v4"
Write-Host "    with:"
Write-Host '      dest: ${{ runner.temp }}/setup-pnpm'
Write-Host ""
Write-Host "Verify in GitHub UI:"
Write-Host "  https://github.com/$RepoOwner/$RepoName/settings/actions/runners"
Write-Host ""
Write-Host "Re-run a workflow:"
Write-Host "  gh run list --branch main --repo $RepoOwner/$RepoName"
Write-Host "  gh run rerun <run-id> --repo $RepoOwner/$RepoName"
Write-Host ""
Write-Host "Rollback to GitHub-hosted runners:"
Write-Host "  gh variable delete USE_SELF_HOSTED --repo $RepoOwner/$RepoName"
Write-Host ""
Write-Host "Deregister a slot: see .NOTES at top of this script."
