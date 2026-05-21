# CI scripts

Helpers for setting up + maintaining self-hosted GitHub Actions runners on
Windows hosts. Proven on `dstefl/lunarpowerpulse` and `dstefl/energeticky-semafor`.

## Scripts

### `setup-self-hosted-runner.ps1`

One-shot installer. From an elevated PowerShell (Run as Administrator):

```powershell
.\setup-self-hosted-runner.ps1 -RepoOwner dstefl -RepoName my-project -RunnerLabels 'my-runner,windows'
```

Idempotent (safe to re-run). What it does:

1. Validates prerequisites: admin elevation, gh + node + git on PATH, x86-64
   architecture, gh authenticated, parent dir writable.
2. Ensures `LocalMachine` PowerShell execution policy is `RemoteSigned`
   (default `Restricted` blocks the runner's temp .ps1 dot-sources).
3. Fetches a registration token + the latest runner release from GitHub API.
4. Downloads + extracts the runner.
5. Configures + installs as a Windows service via `config.cmd --runasservice`.
6. Verifies the service reached Running + Git Bash precedes WSL on machine PATH
   (the `shell: bash` workflow gotcha — see `fix-runner-bash-path.ps1` below).
7. Optionally flips `vars.USE_SELF_HOSTED=true` so workflows route to the new
   runner (skip with `-NoAutoToggle` for staged rollouts).

### `fix-runner-bash-path.ps1`

In-place repair for an already-installed runner whose workflows fail with
`WSL_E_DEFAULT_DISTRO_NOT_FOUND` on `shell: bash` steps. Prepends Git Bash to
the machine PATH so it wins the bash resolution vs Windows' bundled WSL
launcher, restarts the runner service so the new PATH propagates.

Also bumps `LocalMachine` exec policy if needed (some `runas` migrations leave
it `Restricted`, which breaks the runner's per-step temp .ps1 dot-sources).

```powershell
.\fix-runner-bash-path.ps1
```

## Prerequisites for both scripts

* Elevated PowerShell session
* `gh` (GitHub CLI), authenticated as a user with admin on the target repo
* `git` (for Git Bash bundled in the install)
* `node` (the workflows that consume this runner typically expect Node)
