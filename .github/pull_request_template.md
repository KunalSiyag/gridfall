## Summary

<!-- What changes and why. Link the issue: Closes #123 -->

## Area

- [ ] sim
- [ ] ai
- [ ] fp
- [ ] world
- [ ] assets
- [ ] tooling / CI

## Testing

- [ ] `tools/gate.sh quick` passes
- [ ] `tools/gate.sh full` passes (gameplay or rendering changes)
- [ ] `pre-commit run --all-files` passes
- [ ] Added or updated a test in `tools/tests/`
- [ ] Checked in game (describe below, screenshots welcome)

<!-- Commands run and anything you could not test. -->

## Checklist

- [ ] Conventional Commit title (`feat(fp): ...`, `fix(sim): ...`)
- [ ] No secrets, API keys or raw prompts in code or logs
- [ ] New gameplay behind a flag in `data/feature_flags.json`, or not needed
- [ ] Docs updated (README, AGENTS.md, docs/) if behaviour or commands changed
- [ ] No new files over 5 MB, or explained here
