---
name: gridfall-gate
description: Run and interpret the GridFall test gate (tools/gate.sh quick/full/render), lint and repository checks before committing or opening a PR. Use after any code change in scripts/ or tools/.
---

# GridFall gate

1. Lint and format: `pre-commit run --all-files`. Fix what it reports; gdformat fixes are safe to commit.
2. Repository checks: `python tools/checks/run_all.py` (from `~/.venvs/gridfall-tools`). It prints one summary table; `-v` shows each finding. Only findings beyond `tools/checks/baselines/` fail.
3. Unit tests: `tools/gate.sh quick` (2-4 min). For one area: `tools/gate.sh quick --only <step-substring>`.
4. Before a PR or after gameplay/rendering changes: `tools/gate.sh full` (adds the orbit and first-person smokes; heavy, holds a machine-wide lock).
5. Read failures from the per-step logs in the printed `GATE_LOG_DIR` and `results.json` there. A step that passed only on retry is flaky; see `docs/runbooks/gate-failure.md`.
6. Python tooling changed? `python -m pytest` (coverage gate of 80% applies).

Report the exact commands run and which passed. Never mark work done with a red gate.
