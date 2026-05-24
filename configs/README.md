# Shared configs

Drop-in config files / templates that more than one of my projects ends
up needing.

## `workflow-toggle-template.yml`

Copy-paste template for a `.github/workflows/ci.yml` with the
`USE_SELF_HOSTED` runner toggle pattern: one repo variable flips every
CI run between GitHub-hosted `ubuntu-latest` and a self-hosted runner
labelled `<repo>-runner`. Pairs with the install scripts in
`scripts/ci/`.

Replace `<repo>-runner` with the label you passed to the runner installer
(e.g. `householdsim-runner`, `lunar-runner`), tweak the workflow steps for
your project, commit.

Includes the multi-runner `dest: ${{ runner.temp }}/setup-pnpm` workaround
baked in by default — see `docs/POWERSHELL_GOTCHAS.md` §4 for why.
