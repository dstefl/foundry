# Shared docs

How-to docs that survive across project repos. Each page is meant to be
linked from a project's CLAUDE.md / contributor guide so the same lessons
don't get re-learned per project.

## Pages

| Page | What it covers |
| ---- | -------------- |
| [`RUNNER_PLAYBOOK.md`](RUNNER_PLAYBOOK.md) | End-to-end playbook for adding self-hosted GitHub Actions runners to a new project. Includes the **copy-paste Claude prompt** at the top — drop it in Claude on any new repo and the rest happens. Covers naming conventions, both install hosts (workstation + VPS), workflow toggle wiring, rollback, troubleshooting, cost model. |
| [`POWERSHELL_GOTCHAS.md`](POWERSHELL_GOTCHAS.md) | Foot-guns hit while writing the runner installers under `scripts/ci/`. StrictMode + missing properties, Get-Service vs Win32_Service, NETWORK SERVICE profile sharing, ASCII-without-BOM, execution policy, service env-var propagation. |
