# CI scripts

Helpers for setting up + maintaining self-hosted GitHub Actions runners.
Proven across `dstefl/lunarpowerpulse`, `dstefl/energeticky-semafor`, and
`dstefl/householdsim` (the householdsim rollout is what shook out the
multi-runner + cache-aware design currently checked in here).

## Scripts

### `setup-self-hosted-runner.ps1` — Windows host (workstation / on-prem)

From an elevated PowerShell (Run as Administrator):

```powershell
.\setup-self-hosted-runner.ps1 `
  -RepoOwner dstefl `
  -RepoName my-project `
  -RunnerLabels 'my-project-runner,windows'
```

Multi-runner mode for parallel CI throughput:

```powershell
.\setup-self-hosted-runner.ps1 `
  -RepoOwner dstefl `
  -RepoName my-project `
  -RunnerLabels 'my-project-runner,windows' `
  -RunnerNamePrefix "$env:COMPUTERNAME-myproj" `
  -Count 4
```

Idempotent (safe to re-run). What it does:

1. Validates prerequisites: admin elevation, `gh + node + git` on PATH, x86-64,
   `gh` authenticated, parent dir writable.
2. Ensures `LocalMachine` PowerShell execution policy is `RemoteSigned`
   (default `Restricted` blocks the runner's temp `.ps1` dot-sources).
3. Provisions shared caches under `$RunnerRoot`:
   - `pnpm-store` → exposed as `PNPM_STORE_PATH` machine env var.
   - `playwright-browsers` → exposed as `PLAYWRIGHT_BROWSERS_PATH`.
   Multiple runners hard-link from the same pnpm store; Playwright skips
   re-downloading Chromium after the first runner populates the cache.
4. Downloads the latest runner zip once; per-slot extracts share the cache.
5. For each slot (1..`-Count`):
   - Tears down any existing config (idempotent).
   - Configures + installs as a Windows service via
     `config.cmd --runasservice` (auto-start on boot).
6. Prepends Git Bash to machine PATH ahead of `system32` so workflow steps
   using `shell: bash` resolve to Git Bash, not the Windows-bundled WSL
   launcher (which fails with `WSL_E_DEFAULT_DISTRO_NOT_FOUND` if no
   distro is installed).
7. Restarts every installed service so it picks up the new PATH + cache
   env vars.
8. Confirms each runner is **Online** to GitHub.
9. Flips `vars.USE_SELF_HOSTED=true` (skip with `-NoAutoToggle` for
   staged rollouts).

### `setup-self-hosted-runner.sh` — Linux host (VPS)

Mirror of the Windows script for a Linux runner on a small VPS (Hetzner CX22,
Contabo VPS 10, OVH VLE, Oracle Free Tier). Auto-installs prereqs (Node 20,
pnpm via corepack, `gh`, jq, git), creates a dedicated `ghactions` system
user, registers + installs as systemd, injects shared-cache env vars into
the unit file. Same env-var-overridable shape:

```bash
sudo REPO_OWNER=dstefl \
     REPO_NAME=my-project \
     RUNNER_LABELS='my-project-runner,linux' \
     ./setup-self-hosted-runner.sh

# 2 parallel slots, don't auto-flip USE_SELF_HOSTED:
sudo REPO_OWNER=dstefl \
     REPO_NAME=my-project \
     RUNNER_LABELS='my-project-runner,linux' \
     COUNT=2 NO_AUTO_TOGGLE=1 \
     ./setup-self-hosted-runner.sh
```

`gh auth login` must be done as the user invoking the script (one-time —
the registration token gets baked into the runner config at install time;
the runner service runs as `ghactions` and doesn't need ongoing gh
credentials).

### `fix-runner-bash-path.ps1`

In-place repair for an already-installed Windows runner whose workflows
fail with `WSL_E_DEFAULT_DISTRO_NOT_FOUND` on `shell: bash` steps.
Prepends Git Bash to the machine PATH and restarts the runner service.
Same logic is baked into `setup-self-hosted-runner.ps1`, so fresh
installs are correct by default; this script is for machines configured
before that fix landed.

## Workflow-side requirements

When running multiple self-hosted runners on the same host (Windows
`-Count >= 2` or Linux `COUNT >= 2`), the workflow has to scope a couple
of action-setup install dirs to per-runner paths. Without this, concurrent
jobs race on the rmdir + extract step and one fails with
`EBUSY: resource busy or locked, rmdir …`.

### `pnpm/action-setup@v4` (required for multi-runner)

```yaml
- name: Setup pnpm
  uses: pnpm/action-setup@v4
  with:
    # Default ~/setup-pnpm is shared across all runners on the same host
    # because they all run as NT AUTHORITY\NETWORK SERVICE on Windows /
    # the same ghactions user on Linux. runner.temp is per-runner.
    dest: ${{ runner.temp }}/setup-pnpm
```

If you hit a similar race with another setup action (e.g.,
`actions/setup-go`, custom binary installers), point them at
`${{ runner.temp }}` or `${{ runner.tool_cache }}` so each runner gets
its own.

## Routing the workflow to your label

The expected pattern in `.github/workflows/*.yml`:

```yaml
runs-on: ${{ vars.USE_SELF_HOSTED == 'true' && 'my-project-runner' || 'ubuntu-latest' }}
```

When `vars.USE_SELF_HOSTED == 'true'`, jobs land on any runner labelled
`my-project-runner`. With multiple runners sharing that label, GitHub
dispatches concurrent jobs in parallel. Setting the variable back to
anything other than `'true'` (or deleting it) routes back to `ubuntu-latest`
in a single command:

```bash
gh variable delete USE_SELF_HOSTED --repo dstefl/my-project
```

## Prerequisites summary

| Tool          | Windows                       | Linux                              |
|---------------|-------------------------------|------------------------------------|
| Admin / sudo  | Run as Administrator          | sudo                               |
| `gh` CLI      | Required, authenticated       | Script installs if missing         |
| Node 20+      | Required                      | Script installs if missing         |
| Git           | Required (bundles Git Bash)   | Script installs if missing         |
| `pnpm`        | Required (via corepack)       | Script installs via corepack       |

## Cost-of-ownership notes

- **GitHub orchestration fee (March 2026):** $0.002/min for self-hosted
  runners on **private** repos. Public repos remain free. Still cheap
  vs the $0.008/min for `ubuntu-latest` minutes.
- **Idle resource cost per slot:** ~150 MB RAM, negligible CPU.
- **Active job cost per slot:** ~2 GB RAM peak (Node + Vitest + Playwright
  Chromium), 2-4 CPU threads.

## VPS shortlist (verified May 2026)

For an always-on Linux runner that picks up jobs while the workstation
is off:

| Provider | Plan | Specs | €/mo | $/mo |
|---|---|---|---:|---:|
| **Hetzner Cloud** | CX22 | 2 vCPU / 4 GB / 40 GB NVMe | 3.79 | ~4.59 |
| Contabo | VPS 10 | 4 vCPU / 8 GB / ~50 GB SSD | 3.60 | ~4.95 |
| OVH | VLE-2 | 2 vCPU / 4 GB / 40 GB SSD | ~5 | ~6 |
| Oracle Cloud | Always Free Ampere A1 | 4 vCPU ARM / 24 GB | 0 | 0 (if capacity) |

Hetzner CX22 has the best NVMe I/O at this price tier. Contabo has the
most RAM for the money but slower disk. Oracle Free Tier is unbeatable
when you can grab ARM Ampere capacity in your region.
