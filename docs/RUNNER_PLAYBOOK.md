# Self-hosted runner playbook (per-project)

Frictionless setup of self-hosted GitHub Actions runners for any new project,
reusing the infrastructure already built for `dstefl/householdsim` and
`dstefl/lunarpowerpulse`.

## TL;DR — the prompt to paste in Claude

> Set up self-hosted GitHub Actions runners for this project using the
> foundry playbook at <https://github.com/dstefl/foundry/blob/main/docs/RUNNER_PLAYBOOK.md>.
> Read the playbook first, then execute it end-to-end. The Windows host
> already has the foundry scripts; the Linux VPS is reachable via SSH alias
> `hsim-runner`. Use `<this-repo-name>-runner` as the label.

That's the whole interface. Claude reads this file, derives owner/name from
`git remote get-url origin`, installs runners on both hosts, wires the
workflow, flips the toggle, verifies online. Sections below cover each
step in the depth Claude needs.

## Infrastructure already in place

| Host | Type | Specs | Capacity (idle vs peak) |
|---|---|---|---|
| `ORWELLBOX` (workstation) | Windows | Ryzen 9 5950X / 32 threads / 64 GB | Each runner slot: ~18 MB idle, ~2 GB peak. Comfortable: 4-6 slots per project. |
| `hsim-runner` (Contabo VPS) | Linux Ubuntu 26.04 | 4 vCPU / 8 GB / 150 GB SSD | Each runner slot: ~107 MB idle, ~2 GB peak. Comfortable: 2 slots per project, 3-4 projects sharing. |

Both hosts are pre-configured:
- pnpm + Node 20+ on PATH
- `gh` CLI installed and authenticated as `dstefl`
- For the VPS: `dan` is the sudo user (`ssh hsim-runner` is the alias); root
  SSH is disabled; UFW + fail2ban running; gh authed for both `dan` and `root`

## Naming conventions (stick to them)

| Field | Pattern | Example for `dstefl/awesome-thing` |
|---|---|---|
| Runner label (workflow `runs-on:`) | `<repo>-runner` | `awesome-thing-runner` |
| Windows runner name prefix | `<COMPUTERNAME>-<repo-short>` | `ORWELLBOX-awthing` |
| Windows runner root | `D:\repos\github\a_runners_<repo>` | `D:\repos\github\a_runners_awesome-thing` |
| Linux runner name prefix | `$(hostname)-<repo-short>` | `vmi3322607-awthing` |
| Linux runner root | `/opt/actions-runners/<repo>` | `/opt/actions-runners/awesome-thing` |

"Repo short" is whatever 4-8 character abbreviation reads naturally. For
ambiguous cases, use the full repo name.

## Per-project install — step by step

### Step 1: Add the workflow toggle

Copy `configs/workflow-toggle-template.yml` from foundry into the project's
`.github/workflows/ci.yml`, then:

1. Replace `<repo>-runner` everywhere with the project's chosen label.
2. Tweak the build/test/lint commands for the project (the template assumes
   a typical pnpm monorepo).
3. **Required for multi-runner mode** — keep this block, don't drop it:
   ```yaml
   - uses: pnpm/action-setup@v4
     with:
       dest: ${{ runner.temp }}/setup-pnpm
   ```
4. Commit + push so the workflow exists before the runner toggle is flipped.

### Step 2: Install runners on the Windows workstation

From an **elevated PowerShell** (Run as Administrator):

```powershell
cd D:\repos\github\foundry
git pull
.\scripts\ci\setup-self-hosted-runner.ps1 `
  -RepoOwner dstefl `
  -RepoName <reponame> `
  -RunnerLabels '<reponame>-runner,windows' `
  -RunnerNamePrefix "$env:COMPUTERNAME-<short>" `
  -RunnerRoot "D:\repos\github\a_runners_<reponame>" `
  -Count 4
```

The script:
- Provisions shared `pnpm-store` and `playwright-browsers` caches under
  `$RunnerRoot` (machine-level env vars).
- Downloads the runner binary once, extracts per slot.
- Registers each slot, installs as a Windows service via `--runasservice`.
- Prepends Git Bash to machine PATH so `shell: bash` works.
- Flips `vars.USE_SELF_HOSTED=true` for the repo.

`-Count 4` is comfortable on the ORWELLBOX hardware. For lighter projects
or if the host is also doing other heavy work, `-Count 2` is fine.

### Step 3: Install runners on the Linux VPS

```bash
# From the workstation:
ssh hsim-runner

# Once logged in (as dan):
cd ~/foundry || git clone https://github.com/dstefl/foundry.git ~/foundry
cd ~/foundry && git pull

# gh must be authenticated as root for the script (it runs via sudo).
# Token is already cached for both dan and root from the householdsim
# install. If gh auth status fails, refresh with:
#   gh auth token | ssh hsim-runner-root 'sudo gh auth login --with-token'

# Run the installer:
sudo REPO_OWNER=dstefl \
     REPO_NAME=<reponame> \
     RUNNER_LABELS='<reponame>-runner,linux' \
     RUNNER_NAME_PREFIX="$(hostname)-<short>" \
     RUNNER_ROOT="/opt/actions-runners/<reponame>" \
     COUNT=2 \
     bash /home/dan/foundry/scripts/ci/setup-self-hosted-runner.sh
```

The script installs each slot as a systemd service, injects
`PNPM_STORE_PATH` + `PLAYWRIGHT_BROWSERS_PATH` into the unit files,
verifies Online with GitHub, flips `USE_SELF_HOSTED=true` (no-op if
already true from Step 2).

`COUNT=2` matches the householdsim baseline. The 8 GB VPS supports up to
3-4 concurrent projects' runners simultaneously without strain.

### Step 4: Verify

```bash
gh api repos/dstefl/<reponame>/actions/runners --jq \
  '.runners[] | "\(.name)\t\(.status)\tbusy=\(.busy)\t\(.labels | map(.name) | join(","))"'
```

Expected: `4 + 2 = 6` rows, all `online`, `busy=false`, labels include
`<reponame>-runner`.

Then push any commit to trigger a real CI run and watch via:

```bash
gh run watch --repo dstefl/<reponame>
```

The first job will warm the pnpm-store + Playwright cache; subsequent
runs land ~30 % faster on the same host.

## Rollback

```bash
# Send all CI back to ubuntu-latest (no install changes):
gh variable delete USE_SELF_HOSTED --repo dstefl/<reponame>

# Fully deregister a runner slot:
# Windows (from elevated PowerShell, inside the slot dir):
cd D:\repos\github\a_runners_<reponame>\1
$svc = Get-Service "actions.runner.dstefl-<reponame>.*" | Select-Object -First 1
Stop-Service $svc -Force; sc.exe delete $svc.Name
$tok = (gh api -X POST repos/dstefl/<reponame>/actions/runners/remove-token | ConvertFrom-Json).token
.\config.cmd remove --token $tok

# Linux (on the VPS):
cd /opt/actions-runners/<reponame>/1
sudo ./svc.sh stop && sudo ./svc.sh uninstall
tok=$(gh api -X POST repos/dstefl/<reponame>/actions/runners/remove-token --jq .token)
./config.sh remove --token "$tok"
```

## Sharing the VPS across projects

Each project gets its own `RUNNER_ROOT` and `RUNNER_LABELS`. Run the
install script multiple times, once per project, with different env vars.
The systemd unit names are unique
(`actions.runner.<owner>-<repo>.<slot-name>`), so they coexist cleanly.

Disk cost per project's 2 slots: ~700 MB × 2 + ~50 MB cache = ~1.5 GB.
Idle RAM per project: ~210 MB. The 8 GB / 150 GB VPS comfortably hosts
3-4 projects' runners with room for active jobs and side workloads.

If two projects' CI runs concurrently, GitHub's dispatch routes each to
the matching runner pool (label-based). No cross-talk.

## What can go wrong (and how to fix)

| Symptom | Cause | Fix |
|---|---|---|
| `EBUSY: resource busy or locked, rmdir … setup-pnpm` | Multi-runner without the `dest: ${{ runner.temp }}/setup-pnpm` workflow guard | Add the `with: dest:` block to `pnpm/action-setup` — see `configs/workflow-toggle-template.yml` |
| `ERROR: gh CLI is not authenticated` (during install) | gh authed for the calling user but not for `root`/admin | Pipe token: `gh auth token \| ssh hsim-runner-root 'sudo gh auth login --with-token'` |
| `Where-Object: PathName cannot be found` (Windows install) | Pre-fix script, before commit `b0dd7fd` in this repo | `git pull foundry`, re-run |
| Runner registers but stays offline | Service not Running, or firewall blocks outbound 443 to api.github.com | `Get-Service actions.runner.*` (Windows) / `systemctl status actions.runner.*` (Linux); check egress |
| `WSL_E_DEFAULT_DISTRO_NOT_FOUND` on `shell: bash` steps | `system32\bash.exe` (WSL launcher) wins PATH lookup over Git Bash | The install script handles this; for an already-installed runner use `scripts/ci/fix-runner-bash-path.ps1` |
| Workflow runs on `ubuntu-latest` despite `USE_SELF_HOSTED=true` | Variable name typo, scope wrong (env var instead of repo variable), or no runner matches the label | `gh variable list --repo dstefl/<repo>` to confirm the var; `gh api repos/.../actions/runners` to confirm a runner has the requested label |
| Branch protection blocks self-hosted run from being required-check | GitHub treats the same job name as a different check when the runner OS changes | Pin a stable job name in the workflow; don't include OS in the job's `name:` field |

## VPS lockdown — how to recover if locked out

The Contabo VPS (`hsim-runner` alias) is hardened with:

- `dan` sudo user (passwordless sudo, key-only login)
- Root SSH **disabled** via `/etc/ssh/sshd_config.d/90-hardening.conf`
- Password authentication **disabled** in the same file
- UFW deny-by-default + fail2ban
- Root password from Contabo's provisioning email still valid for VNC console only

### Re-enable root SSH (key-based, recommended)

Public key is still in `/root/.ssh/authorized_keys` — just flip the directive:

```bash
ssh hsim-runner 'sudo sed -i "s/^PermitRootLogin no/PermitRootLogin yes/" /etc/ssh/sshd_config.d/90-hardening.conf && sudo sshd -t && sudo systemctl reload ssh && echo OK'
```

`ssh hsim-runner-root` then works (alias kept in `~/.ssh/config` for this case).

### Re-enable password root SSH (e.g., from a machine without your key)

```bash
ssh hsim-runner 'sudo sed -i -e "s/^PermitRootLogin no/PermitRootLogin yes/" -e "s/^PasswordAuthentication no/PasswordAuthentication yes/" /etc/ssh/sshd_config.d/90-hardening.conf && sudo sshd -t && sudo systemctl reload ssh && echo OK'
```

### Scrub hardening entirely

```bash
ssh hsim-runner 'sudo rm /etc/ssh/sshd_config.d/90-hardening.conf && sudo systemctl reload ssh && echo OK'
```

### Locked out completely (no SSH path works)

Use Contabo's browser VNC console — it's a direct VM virtual TTY, NOT
SSH-mediated, so the sshd config doesn't apply:

1. Contabo Customer Control Panel → your VPS → **VNC Console**
2. Log in as `root` with the password from the provisioning email
3. `rm /etc/ssh/sshd_config.d/90-hardening.conf && systemctl reload ssh`
4. SSH access restored

The VNC console is the always-available escape hatch. That's the
recoverability guarantee that makes the rest of the hardening safe.

## Trust + token hygiene

`gh` on the VPS holds a token cached at `/home/dan/.config/gh/hosts.yml`
and `/root/.config/gh/hosts.yml`. Scopes: `repo`, `workflow`, `gist`,
`read:org` (whatever the local install was authed with). The runner
binary itself doesn't need ongoing gh — it bakes a per-runner
credential into `.credentials` at install time.

When wrapping a development session, optionally clean up:

```bash
ssh hsim-runner 'sudo gh auth logout --hostname github.com -y; gh auth logout --hostname github.com -y'
```

The runners keep working. Future installs need to re-auth first.

## Cost model

- **GitHub Actions billing** for self-hosted on private repos: $0.002/min
  orchestration fee only. Negligible vs $0.008/min on `ubuntu-latest`.
- **VPS**: Contabo VPS 10 — $4.95/mo. Hosts 3-4 projects' runners
  comfortably. Per-project marginal cost: $0.
- **Workstation**: $0 marginal (already running).

For perspective: 6 runners × 30 CI runs/month × 5 min/run = 900 min/month
of CI time. On `ubuntu-latest` that's $7.20/month per repo. On self-hosted
it's ~$1.80/month per repo on private, $0 on public. The VPS pays for
itself within ~3 projects.
