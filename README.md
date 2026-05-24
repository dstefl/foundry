# `dstefl/foundry` — shared assets + tools

Cross-project library of curated audio assets, CI scripts, configs, and
how-to docs that more than one of my projects ends up needing. Born from
duplicating the same `setup-self-hosted-runner.ps1` between
`lunarpowerpulse` and `energeticky-semafor`, plus a 17-entry curated
Freesound SFX catalog that other game / interactive projects can reuse.

## What's here

| Path | Purpose |
| ---- | ------- |
| [`audio/sfx/_catalog.json`](audio/sfx/_catalog.json) | Curated CC0 Freesound sound-effect catalog. Metadata + Freesound URLs only — consuming projects fetch the audio via the Freesound public preview CDN. 17 entries across 10 game-event slots (click, dawnChime, habitatCrack, etc.) with intent notes + processing recommendations. |
| [`scripts/audio/`](scripts/audio/) | Audio toolchain shared across projects: SFX encode pipeline (Demucs + ffmpeg → Opus), music-stem encode pipeline, intro-cinematic offline-render via Playwright + Tone.js. |
| [`scripts/ci/`](scripts/ci/) | Self-hosted GitHub Actions runner installer (Windows `.ps1` + Linux `.sh`, multi-runner + cache-aware) + Git Bash PATH repair helper. Drives both ORWELLBOX (workstation) and the Contabo VPS (`hsim-runner` SSH alias) from one script per OS. |
| [`docs/RUNNER_PLAYBOOK.md`](docs/RUNNER_PLAYBOOK.md) | **Per-project quickstart for adding runners to a new repo.** Includes a copy-paste Claude prompt — drop into any new project and the rest is automatic. |
| [`scripts/smoke/`](scripts/smoke/) | Production health-check smoke runners. |
| [`configs/`](configs/) | Shared `.editorconfig`, `.gitattributes`, `tsconfig.base.json`. |
| [`docs/`](docs/) | How-to docs that survive across project repos — audio sourcing, runner setup, etc. |

## How a consuming project uses it

Two patterns work well:

1. **Git submodule.** Pin a specific commit, get reproducible builds.
   ```
   git submodule add https://github.com/dstefl/foundry.git tools/foundry
   ```
   Then reference scripts as `tools/foundry/scripts/audio/...`.

2. **Copy + adapt.** For one-off scripts that need project-specific
   defaults (e.g. runner installer with a per-project repo URL), copy
   the script into the project's `scripts/` and adapt. This is what
   `lunarpowerpulse` + `energeticky-semafor` currently do.

## License

MIT for code (scripts, configs). All audio entries in `audio/sfx/_catalog.json`
point to **Creative Commons 0 (CC0)** sources — public domain dedication;
no attribution legally required (but provided in the catalog so consuming
projects can credit authors voluntarily).

See [`LICENSE`](LICENSE).

## Provenance

Initial commit imports proven scripts + curated catalog from
[`dstefl/lunarpowerpulse`](https://github.com/dstefl/lunarpowerpulse).
History in that repo (PRs #341–#368) documents the design + iteration
behind the audio pipeline; this repo carries the distilled reusable bits.
