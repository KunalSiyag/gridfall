# Contributing to GridFall

Thanks for helping. `AGENTS.md` has the short version of everything below and is what coding agents read.

## Getting started

```bash
git clone https://github.com/KunalSiyag/gridfall.git && cd gridfall
tools/setup.sh                 # Python venv, pinned tools, pre-commit hooks, asset import
GRIDFALL_OFFLINE=1 godot --path .
```

You need Godot 4.7.x (`.godot-version`) and Python 3.10+. A GMI key is optional; offline play uses the replay cache and heuristics. A ready-made environment is in `.devcontainer/`.

## Workflow

1. Open or pick an issue. Labels: `type/*` (bug, feature, chore), `area/*` (sim, ai, fp, world, assets, tooling), `priority/p0..p3`.
2. Branch from `main`: `feat/<short-name>`, `fix/<short-name>`, `chore/<short-name>`.
3. Make the change with a test. Keep PRs focused.
4. Run `pre-commit run --all-files`, `python tools/checks/run_all.py` and `tools/gate.sh quick` (and `full` for gameplay or rendering changes) from the tools venv.
5. Open a PR using the template. CI must be green and one review is required before merge to `main`.

## Code style

- GDScript follows the official Godot style guide, enforced by `gdlint` and `gdformat` (config in `gdlintrc`).
- Naming: `snake_case` for files, functions, variables and signals; `PascalCase` for `class_name` and node names; `UPPER_SNAKE_CASE` for constants and enum values; a leading `_` for private members and virtual overrides.
- Keep functions small. The complexity check fails above the threshold in `tools/checks/complexity.py`; split long functions rather than raising it.
- Leave `TODO`/`FIXME` only with an issue link (`TODO(#123): ...`); `tools/checks/todo_scan.py` reports untracked ones.
- Use typed GDScript (`var x: int`, `-> void`) for new code.

## Commits and releases

Conventional Commits: `type(scope): summary`, for example `feat(fp): overview site markers`. Types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `chore`, `ci`, `build`. Release notes and `CHANGELOG.md` are generated from these. See `docs/runbooks/release-and-rollback.md`.

## Security

Do not commit keys or tokens. The pre-commit hooks scan for secrets. Report vulnerabilities privately to the maintainer rather than in a public issue.
