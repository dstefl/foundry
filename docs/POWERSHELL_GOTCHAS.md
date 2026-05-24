# PowerShell gotchas (cross-project)

Footnotes from real PowerShell scripts that ship in foundry, especially the
runner installers under `scripts/ci/`. Things that aren't obvious until they
break, ordered by frequency of bite.

## 1. `Get-Service` doesn't expose `.PathName`

Looks like it should — services have a binary path, you can see it in
services.msc — but `Get-Service` returns `System.ServiceProcess.ServiceController`
objects, and `PathName` lives on `System.Management.ManagementObject` (the
WMI / CIM representation).

```powershell
# Won't work — and under Set-StrictMode -Version Latest it's a HARD ERROR,
# not just $null:
Get-Service "actions.runner.*" | Where-Object { $_.PathName -like "*foo*" }
# Where-Object : The property 'PathName' cannot be found on this object.
```

**Fix — use Win32_Service via CIM:**

```powershell
Get-CimInstance Win32_Service -Filter "Name like 'actions.runner.%%'" |
  Where-Object { $_.PathName -like "*foo*" }
```

**Or skip the filter entirely** — write the deterministic name to a file at
install time and read it back. That's what `scripts/ci/setup-self-hosted-runner.ps1`
does (the `.service` file dropped by `config.cmd`).

## 2. `Set-StrictMode -Version Latest` makes missing properties fatal

Without StrictMode, accessing a property that doesn't exist returns `$null`.
With it, it's an exception. Combined with #1, this is the most common script
crash. Always test scripts WITH StrictMode enabled because that's the only way
to catch latent bugs:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
```

Other StrictMode-fatal patterns:
- Reading `$Args[5]` when only 4 args were passed
- `$hash.MissingKey` on a hashtable
- Reading uninitialised variables (`$x` before `$x = ...`)

## 3. Pure ASCII for PS 5.1 + no BOM

Windows PowerShell 5.1 reads `.ps1` files without a BOM as ANSI / CP-1252
(varies by locale!) rather than UTF-8. Em-dashes, bullets, box-drawing chars,
checkmarks, smart quotes — anything non-ASCII — will tokenise wrong and crash
the parser at random.

**Rule:** keep `.ps1` files pure ASCII unless you commit them with a UTF-8
BOM. PowerShell 7+ defaults to UTF-8-without-BOM, so the rule only applies
when supporting 5.1 (which most corporate Windows hosts still default to).

Easy in-editor check: VS Code's status bar shows the encoding bottom-right.

## 4. `--runasservice` runs as `NT AUTHORITY\NETWORK SERVICE` by default

Multiple GitHub Actions runner instances on the same host all share the
NETWORK SERVICE user profile (`C:\WINDOWS\ServiceProfiles\NetworkService\`).
Any setup-action that writes to `$HOME` will race when 2+ runners start a
job concurrently.

Specifically, `pnpm/action-setup@v4`'s default `~/setup-pnpm` lands in the
shared profile. Workflow-side fix:

```yaml
- uses: pnpm/action-setup@v4
  with:
    dest: ${{ runner.temp }}/setup-pnpm
```

`runner.temp` is per-runner and cleaned between jobs. The same pattern
applies to any action that writes to `$HOME` / `~/.cache` / `%USERPROFILE%`.

Alternative: register each runner under a separate Windows user via
`config.cmd --windowslogonaccount`. Heavier setup, cleaner isolation if
you have user-management automation already.

## 5. Service env vars don't pick up unless the service is restarted

`[Environment]::SetEnvironmentVariable($k, $v, 'Machine')` writes the var
to the registry, but already-running services keep the env they inherited
at start time. After updating machine env vars, restart any services that
depend on them:

```powershell
foreach ($s in $services) {
    Restart-Service -Name $s -Force
}
```

User-level env vars (`'User'`) DON'T propagate to services running as
NETWORK SERVICE / LOCAL SERVICE / LOCAL SYSTEM at all. Use `'Machine'`
scope when targeting service principals.

## 6. `Get-Service` + service name patterns

`Get-Service -Name "actions.runner.*"` works (wildcards allowed in `-Name`).
But under StrictMode, piping with `Select-Object -First 1` on an empty result
silently returns `$null`, and accessing `.Name` on `$null` is fatal. Always
null-check:

```powershell
$svc = Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue |
       Select-Object -First 1
if (-not $svc) {
    throw "No actions.runner.* service found."
}
```

## 7. Execution policy + script-generated scripts

The GitHub Actions runner writes temp `.ps1` files for every workflow step
and dot-sources them. Default `LocalMachine` policy is `Restricted`, which
blocks ALL `.ps1` loading regardless of source.

Set it to `RemoteSigned` (or `Bypass` for trusted hosts) at machine scope:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
```

User-scope policies don't help — the runner service runs as NETWORK SERVICE
and inherits machine-scope.

## 8. `Stop-Service` + `sc.exe delete` for clean teardown

Modern runner (v2.300+) ships without `svc.cmd`, so use the OS-level service
controller for uninstalls:

```powershell
Stop-Service $svc -Force -ErrorAction SilentlyContinue
& sc.exe delete $svc.Name 2>&1 | Out-Null
```

`Stop-Service` is async by default — pair with `(Get-Service ...).WaitForStatus('Stopped')`
if you need to be sure it's down before deletion. Usually not needed because
`sc.exe delete` is queued by the SCM until the service stops anyway.

## 9. `Restart-Service -Force` doesn't always force

`-Force` only allows stopping services with dependent services. If the
service is hung in `Stopping` state, `Restart-Service` will block waiting
for it to die. Kill the worker process directly first:

```powershell
$pid = (Get-CimInstance Win32_Service -Filter "Name='$svcName'").ProcessId
if ($pid -gt 0) { Stop-Process -Id $pid -Force }
Start-Service $svcName
```

## 10. PowerShell 5.1's `Invoke-WebRequest` defaults

`Invoke-WebRequest` in 5.1 uses Internet Explorer's parser to read the
response body. On a fresh Windows install, IE first-run dialogs can hang
the call. Always add `-UseBasicParsing`:

```powershell
Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -TimeoutSec 300
```

PowerShell 7+ doesn't have this issue — `-UseBasicParsing` is a no-op there.
Add it anyway for portability.
