# Runbooks

Short, step-by-step fixes for things that go wrong while developing or playing GridFall. Each runbook lists symptoms, how to confirm, the fix and how to verify.

| Runbook | Use when |
| --- | --- |
| [gmi-outage.md](gmi-outage.md) | Mayors fall back to cache or heuristics, GMI Log shows errors, circuit breaker is open |
| [gate-failure.md](gate-failure.md) | `tools/gate.sh` or CI goes red |
| [asset-import.md](asset-import.md) | Models are missing or pink, the editor re-imports forever, `.godot/` is corrupt |
| [gpu-memory.md](gpu-memory.md) | The game will not load, stays black or glitches heavily; the log shows `VkResult -2` (out of GPU memory) |
| [save-corruption.md](save-corruption.md) | A save will not load or loads an empty city |
| [error-triage.md](error-triage.md) | Turning the local error log into GitHub issues |
| [release-and-rollback.md](release-and-rollback.md) | Cutting a release, or pulling a bad one |
| [web-deploy.md](web-deploy.md) | Building, shipping or verifying the web demo on GMI AgentBox |
| [linux-standalone.md](linux-standalone.md) | Building, packaging, running or benchmarking the native Linux build for the presenter machine; Vulkan, sound or black-window trouble on it |
| [web-probe-kit.md](web-probe-kit.md) | Finding where a web-build hitch goes (shader links, uploads, readbacks), or measuring the web build at another viewport or pixel ratio |
| [ask-the-five.md](ask-the-five.md) | Demoing Ask the five with a key, a column shows a 429 or an error, or a keyless visitor asks what they are seeing |
| [model-ledger.md](model-ledger.md) | Reading the league's Orders, Speed and health lights, the Arena tab or Services & minds; a model shows red; chat lines say press office or own words |
| [police-response.md](police-response.md) | The screen stays black after a bust, police officers or a chase are stuck, or the police seem to do nothing |
| [soak.md](soak.md) | The nightly long-session soak (40 game days at 8x) fails, or you want to check that a change does not leak nodes, memory or save size |
| [monitoring.md](monitoring.md) | Where to look: CI runs, releases, code scanning, quality report, alerts |

When you fix something that is not covered here, add a runbook in the same format.
