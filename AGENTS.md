# AGENTS.md

Guidance for coding agents (and humans) working in GridFall, a Godot 4.7 city builder whose AI mayors run on GMI Cloud. Read `README.md` for what the game does and `docs/fp/ARCHITECTURE.md` for how the first-person / third-person layer is built.

## Setup

- Godot **4.7.x** (see `.godot-version`) must be on `PATH` as `godot`.
- Python 3.10+ for the tooling. One command sets up everything else (venv at `~/.venvs/gridfall-tools`; activate it before running the tools):

  ```bash
  tools/setup.sh          # venv, pinned Python tools, pre-commit hooks, first asset import
  ```

- First launch imports ~460 MB of assets into `.godot/` (several minutes). Never commit `.godot/`.
- GMI calls need `GMI_API_KEY`. Without it (or with `GRIDFALL_OFFLINE=1`) the game uses the replay cache in `data/gmi_replay_cache.json`, then heuristics. Tests always run offline. Copy `.env.example` for the full list of environment switches.

## Test

```bash
tools/gate.sh quick     # parse check + every unit test (~2-4 min). Run before every commit.
tools/gate.sh full      # quick + orbit and first-person headless smokes. Run before a PR.
tools/gate.sh render    # windowed photo tour + perf report (needs a display; optional)
godot --headless --path . -s tools/tests/<name>_test.gd   # one test file
```

Static checks and Python tests:

```bash
pre-commit run --all-files          # gdlint, gdformat --check, large files, secrets, yaml
python tools/checks/run_all.py      # complexity, dead code, duplicates, boundaries, TODOs, flags
python -m pytest                    # Python tooling tests (tools/pytests), coverage >= 80%
```

A test prints `PASS`/`FAIL` lines and exits non-zero on failure. Gate logs go to `$GATE_LOG_DIR` (default `/tmp/claude-1000/gf-gate-<branch>-<ts>/`) with `results.json` (result and seconds per step). `GATE_RETRIES=1` re-runs a failed step once and records it in `flaky.txt`. Repo checks compare against `tools/checks/baselines/`, so only new findings fail.

## Layout

- `scripts/sim/`: pure simulation (`city_sim.gd`, `residents.gd`, `sim_defs.gd`). No nodes, no rendering.
- `scripts/ai/`: GMI client and prompts. All network traffic goes through `scripts/ai/gmi_client.gd`.
- `scripts/world/`: orbit-view renderer, traffic, sky. `scripts/ui/`: orbit HUD.
- `scripts/fp/`: first/third-person mode. Each feature is a folder registered in `scripts/fp/fp_features.gd`.
- `scripts/ops/`: retry and circuit breaker, tracing, log redaction, opt-in error log and analytics, feature flags.
- `tools/tests/`: Godot test scripts (`*_test.gd`). `tools/checks/`: repository checks. `tools/blender/`: asset pipeline.
- `models/`, `textures/`, `sounds/`, `env/`: assets. Large; do not rewrite or re-export without a reason.
- `docs/runbooks/`: what to do when something breaks.

## Rules

- Keep the sim deterministic and headless-safe: no `Node`/scene access from `scripts/sim/`, no randomness without the sim seed.
- New first-person features go in their own `scripts/fp/<feature>/` folder and talk to others through `scripts/fp/game_bus.gd` signals, not direct references. `tools/checks/boundaries.py` enforces the import rules.
- Never call the network outside `GmiClient`. Never log API keys or raw prompts; route log text through the redactor in `scripts/ops/`.
- Analytics and the error log are opt-in (`GRIDFALL_ANALYTICS=1`, `GRIDFALL_ERROR_LOG=1`) and stay local. Do not add outside services.
- Gate new behaviour behind a flag in `data/feature_flags.json` when it changes gameplay; remove the flag once it ships.
- Naming: `snake_case` files, functions and variables; `PascalCase` `class_name`s and nodes; `UPPER_SNAKE` constants; private members start with `_`. Tests are `tools/tests/<area>_test.gd`.
- Add or update a test with every behaviour change and keep `tools/gate.sh quick` green.
- Do not edit `project.godot` by hand beyond the section you need; the editor rewrites it.
- Do not commit `.godot/`, recordings or exports. Files over 12 MB are rejected by the hooks; anything over 5 MB needs a reason in the PR.
- Commits use Conventional Commits (`feat(fp): ...`, `fix(sim): ...`, `chore(ci): ...`); `tools/changelog.py` builds release notes from them.
