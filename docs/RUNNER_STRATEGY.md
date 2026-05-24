# Self-Hosted Runner Strategy

Companion to [`RUNNER_PLAYBOOK.md`](./RUNNER_PLAYBOOK.md). The playbook tells you **how to install** runners. This tells you **how to route work** to them — and how to avoid the common ways CI performance is silently wasted.

## TL;DR Prompt for Claude

> Tune this project's self-hosted runner routing per the foundry strategy at https://github.com/dstefl/foundry/blob/main/docs/RUNNER_STRATEGY.md. Read the doc, then for each job in `.github/workflows/ci.yml` choose the right `runs-on` label array per the workload table; apply the performance checklist (especially: drop `cache: pnpm` on self-hosted — saves ~2 min/run on the corp-TLS path). Don't add parallel splits or auto-fallback workflows unless the heuristic explicitly says so. Show me the diff before pushing.

## The pools

| Pool | Hosts | Slots | Strengths | Weaknesses |
|---|---|---|---|---|
| **Windows workstation** (e.g. ORWELLBOX) | 1 | 4 | Ryzen 9 / 32 threads / 64 GB; high single-slot throughput; persistent local pnpm-store + Playwright cache via foundry's `PNPM_STORE_PATH` machine env var. | Reboots / sleeps / user-busy. Bound to one machine. Often behind a corp TLS-intercepting proxy that adds re-encryption overhead. Bandwidth is usually a home connection (asymmetric, slow upload — e.g. 110 ↓ / 18 ↑ Mbps is typical). |
| **Linux VPS** (e.g. Contabo `hsim-runner`) | 1 | 2 per project, 3–4 projects shared | **Always-on** (independent of the workstation's sleep / reboot / user activity); **high symmetric DC bandwidth** (typically 200+ Mbps both ways — ~10× a typical home upload); **clean network path** (no corp TLS proxy); cheap (~$5/mo for the box, $0 marginal per project). Good for Docker, scheduled jobs, upload-heavy deploys, overflow. | Lower per-slot perf (4 vCPU / 8 GB shared across projects). |

Capacity in a typical install: **4 Windows + 2 Linux = 6 slots** per project. GitHub Actions distributes a broadly-labelled job by whichever slot picks it up first, which is roughly **2:1 Windows-leaning** by slot count.

### Network and uptime — when they tip the decision

Two underrated VPS advantages most projects forget about:

- **Always-on.** Scheduled jobs (cron-triggered nightly Stryker, weekly deep-fuzz, every-6h smoke-prod) need a runner that's up at 02:00 regardless of whether the workstation has been put to sleep. Pin those to `linux`.
- **Bandwidth, especially upload.** Cloudflare Pages deploys, coverage uploads, GH Actions cache writes (if you ever re-enable `cache: pnpm`), Playwright test-report uploads — all upload-bound. A 50 MB deploy artifact on an 18 Mbps home upload takes ~22 s; on a 200 Mbps DC link it's ~2 s. If your deploy job is part of every `main` push, that compounds. Pin deploys to `linux` if upload time noticeably dominates the job.

For a project with a small bundle (Gridomics-scale, ~5 MB Cloudflare artifact) the deploy upload delta is sub-second on either pool — not worth pinning. For a project with a 100+ MB build artifact (image-heavy site, large bundled fonts, packaged native binaries), the delta is real.

## The label model

The foundry install script registers every slot with this label set:

- `self-hosted` — generic GH label, present on every self-hosted runner everywhere.
- OS label: `windows` (Windows host) or `linux` (Linux VPS).
- Architecture: `X64`.
- `<repo>-runner` — your project's specific label (e.g. `gridomics-runner`, `householdsim-runner`).

`runs-on` matches **all** labels in the array (intersection). Use the array form for selection.

## When to use which `runs-on` array

| Pattern | When | Why |
|---|---|---|
| `[self-hosted, <repo>-runner]` | **Default.** Cross-platform job, single sequential pipeline. | All 6 slots usable. ORWELLBOX claims ~2/3 by capacity; VPS picks up overflow. Zero added complexity. |
| `[self-hosted, windows, <repo>-runner]` | Job with a Windows-only dependency, OR heavy enough that the per-slot perf delta matters (Playwright E2E, large bundles, big Vite production builds). | ORWELLBOX is faster per slot. Persistent Playwright browsers cache lives there via `PLAYWRIGHT_BROWSERS_PATH`. |
| `[self-hosted, linux, <repo>-runner]` | (a) Linux-only need (Docker host, certain system libs, distro-specific binary); (b) **scheduled / overnight job** (mutation testing, deep fuzz, smoke-prod cron) — the workstation may be asleep; (c) **upload-heavy job** (large deploy artifact, coverage / report uploads) — the VPS's ~200 Mbps DC upload beats a home ~18 Mbps upload by ~10×; (d) long-running job that shouldn't tie up workstation slots during business hours. | VPS is always-on, has symmetric DC bandwidth, and is decoupled from the desk machine. |
| `ubuntu-latest` (literal, no array) | Manual escape hatch. Only via `gh variable delete USE_SELF_HOSTED --repo dstefl/<repo>`. | Don't hard-code this branch — the `${{ vars.USE_SELF_HOSTED == 'true' && ... || 'ubuntu-latest' }}` pattern in the workflow-toggle template already handles it. |

## Single-job vs split-jobs heuristic

**Default: one `all-checks` job.** Sequential is simpler and faster on small suites because each parallel job re-pays the `pnpm install` + `setup-node` cost.

**Split when at least one of these is true:**

1. **One step is multi-minute AND the rest are fast** — typical case: Playwright E2E (~3–10 min) vs unit tests (~30s). Split E2E to its own job so a flaky E2E doesn't block fast feedback on the rest.
2. **Two steps are genuinely independent AND would benefit from parallelism** — e.g. visual regression vs unit tests. The total wall-clock is `max(jobs)` instead of `sum(jobs)`.
3. **One step requires a different runner type** — e.g. a Docker integration test that needs Linux in an otherwise Windows-preferred pipeline.
4. **A periodic audit job exists** — Stryker mutation testing, deep property fuzz, security audit. Schedule separately on the VPS so it doesn't burn workstation slots overnight.

**Don't split:**
- A suite where the total is < 1 min and no single step dominates.
- "Just in case it grows" — split when it actually grows, not before.

## Performance tuning checklist

- [ ] **No `cache: pnpm` on `setup-node@v4` when running on self-hosted.** The foundry install script provisions a machine-level shared pnpm-store at `$PNPM_STORE_PATH` that's hard-linked across all slots and survives runs. The GH Actions cache round-trip is pure overhead — measured **~2 min per run lost** on a corp-TLS path (Gridomics 26370987662 → 26371140978 comparison: 3m 33s → 1m 31s by removing one line). If you ever fall back to `ubuntu-latest` for real (no persistent FS), re-add `cache: pnpm` there only.
- [ ] **`pnpm/action-setup` has `dest: ${{ runner.temp }}/setup-pnpm`.** Without it, parallel runner slots sharing `$HOME` race on rmdir + extract and crash with `EBUSY`. Mandatory for `Count >= 2`.
- [ ] **Use Turbo for the per-package fan-out** (`pnpm test`, `pnpm typecheck`, etc.). Turbo parallelises across packages by default; you don't need to split jobs to get per-package parallelism within one runner.
- [ ] **`concurrency:` group on the deploy job.** Prevents overlapping deploys on rapid `main` pushes; pair with `cancel-in-progress: false` so in-flight deploys complete (don't leave deployed artifact and source SHA mismatched).
- [ ] **Pin job-step versions, not floating tags**, for `actions/checkout@v4` and friends — even though GitHub bumps automatically, explicit majors make Dependabot churn legible.
- [ ] **`timeout-minutes:` on every job.** Default is 360 (6 h); set 15–30 for normal CI, 60+ only for E2E / mutation runs.
- [ ] **Don't add `if: success()`** — that's the default; it adds noise without behaviour change.
- [ ] **For npm projects: same `cache: 'npm'` rule applies.** Drop it from `setup-node@v4` on self-hosted. `~/.npm/_cacache` persists across runs on the runner's disk; the GH Actions cache layer is the same corp-TLS overhead. Re-add `cache: 'npm'` only when falling back to ephemeral `ubuntu-latest` (e.g. the `visual-baselines` workflow that's permanently pinned there for OS parity).
- [ ] **In `${{ cond && X || Y }}` ternaries, never use `''` for `X`.** GHA expressions short-circuit on falsy values, and the empty string is falsy. So `runner.os == 'Windows' && ''` resolves to `''`, then `|| Y` clobbers it back to whatever `Y` was — the inverse of what you wanted. Use a non-empty placeholder (`'0'`, `'off'`, `'skip'`) that the consuming gate treats as off. Hit by lunarpowerpulse PR #376 with `PLAYWRIGHT_VISUAL: ${{ runner.os == 'Windows' && '' || vars.PLAYWRIGHT_VISUAL }}` — visual tests ran on Windows anyway and all 4 failed against Ubuntu-generated baselines. Fix was `'' → '0'`. The same trap applies to `'false'` (truthy as a string) vs an actual boolean.

## Example layouts

### Small / fast project (current Gridomics, householdsim before it grows)

One job, broad label, no cache:pnpm. Whole pipeline runs in ~1–2 min.

```yaml
jobs:
  all-checks:
    name: All checks
    runs-on: ${{ vars.USE_SELF_HOSTED == 'true' && fromJSON('["self-hosted","<repo>-runner"]') || fromJSON('["ubuntu-latest"]') }}
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with:
          dest: ${{ runner.temp }}/setup-pnpm
      - uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc
          # No `cache: pnpm` on self-hosted — see strategy doc.
      - run: pnpm install --frozen-lockfile
      - run: pnpm lint
      - run: pnpm typecheck
      - run: pnpm test
      - run: pnpm build
```

### Medium project — split E2E to a Windows-pinned job

E2E is the slow + GUI-rendering-sensitive thing; pin it to ORWELLBOX. Everything else broad.

```yaml
jobs:
  checks:
    runs-on: ${{ vars.USE_SELF_HOSTED == 'true' && fromJSON('["self-hosted","<repo>-runner"]') || fromJSON('["ubuntu-latest"]') }}
    timeout-minutes: 15
    steps: [ ... install + lint + typecheck + unit-test + build ]

  e2e:
    name: Playwright E2E
    needs: checks
    runs-on: ${{ vars.USE_SELF_HOSTED == 'true' && fromJSON('["self-hosted","windows","<repo>-runner"]') || fromJSON('["ubuntu-latest"]') }}
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with:
          dest: ${{ runner.temp }}/setup-pnpm
      - uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc
      - run: pnpm install --frozen-lockfile
      - run: pnpm --filter @<scope>/web exec playwright install chromium  # cached via PLAYWRIGHT_BROWSERS_PATH
      - run: pnpm --filter @<scope>/web e2e

  deploy-prod:
    needs: [checks, e2e]
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ${{ vars.USE_SELF_HOSTED == 'true' && fromJSON('["self-hosted","<repo>-runner"]') || fromJSON('["ubuntu-latest"]') }}
    concurrency:
      group: deploy-prod
      cancel-in-progress: false
    steps: [ ... wrangler deploy ... ]
```

### Periodic audit — pin to Linux VPS

Stryker / deep-fuzz / nightly cross-validation. Long-running and off-hours; doesn't compete for workstation slots.

```yaml
on:
  schedule:
    - cron: "0 2 * * 1"   # Mondays 02:00 UTC
  workflow_dispatch:

jobs:
  mutation:
    name: Mutation testing (Stryker)
    runs-on: ${{ vars.USE_SELF_HOSTED == 'true' && fromJSON('["self-hosted","linux","<repo>-runner"]') || fromJSON('["ubuntu-latest"]') }}
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with:
          dest: ${{ runner.temp }}/setup-pnpm
      - uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc
      - run: pnpm install --frozen-lockfile
      - run: pnpm --filter @<scope>/grid-model stryker
```

## What we deliberately don't do

### Auto-fallback `Windows → Linux → ubuntu-latest`

Approximating priority fallback via `continue-on-error` + dependent jobs is ~40 extra lines of YAML and has subtle gotchas: a *test* failure on Windows would falsely route to Linux, masking the real bug. The manual `gh variable delete USE_SELF_HOSTED` toggle is one command and observable. Don't build the fallback ladder.

### `cache: pnpm` on self-hosted

Covered in the checklist. Removing it was a ~58 % speed-up on Gridomics. Almost every project copy-pastes the cache line without thinking; this is the highest-leverage perf change you'll make.

### Splitting jobs purely for parallelism on a small suite

Parallel-job overhead (install + node-setup, paid per job) typically dominates the small-job wall-clock savings. Wait until you have a multi-minute outlier step that's worth isolating.

### Hard-coding `ubuntu-latest`

The workflow-toggle template gives you the conditional that respects `vars.USE_SELF_HOSTED`. Use it. Hard-coded `ubuntu-latest` defeats the rollback hatch.

## See also

- [`RUNNER_PLAYBOOK.md`](./RUNNER_PLAYBOOK.md) — install steps.
- [`POWERSHELL_GOTCHAS.md`](./POWERSHELL_GOTCHAS.md) — PS quirks when working with the install script.
- [`configs/workflow-toggle-template.yml`](../configs/workflow-toggle-template.yml) — drop-in workflow shape.
