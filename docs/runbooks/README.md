# Runbooks

Short, step-by-step fixes for things that go wrong while developing or playing GridFall. Each runbook lists symptoms, how to confirm, the fix and how to verify.

| Runbook | Use when |
| --- | --- |
| [gmi-outage.md](gmi-outage.md) | Mayors fall back to cache or heuristics, GMI Log shows errors, circuit breaker is open |
| [gate-failure.md](gate-failure.md) | `tools/gate.sh` or CI goes red |
| [asset-import.md](asset-import.md) | Models are missing or pink, the editor re-imports forever, `.godot/` is corrupt |
| [save-corruption.md](save-corruption.md) | A save will not load or loads an empty city |
| [error-triage.md](error-triage.md) | Turning the local error log into GitHub issues |
| [release-and-rollback.md](release-and-rollback.md) | Cutting a release, or pulling a bad one |
| [monitoring.md](monitoring.md) | Where to look: CI runs, releases, code scanning, quality report, alerts |

When you fix something that is not covered here, add a runbook in the same format.
