# Error triage: local error log to GitHub issues

The error tracker is local and opt-in. Nothing leaves the machine unless you run the issue tool yourself.

1. Play or run tests with `GRIDFALL_ERROR_LOG=1` (or turn on the `error_tracking` flag). Script errors, `push_error`/`push_warning` and GMI failures go to `user://ops/errors.jsonl` with context: fingerprint, trace id, session, build, game context, recent breadcrumbs and the script backtrace. Text goes through the redactor (`scripts/ops/redact.gd`) first, so keys, tokens and e-mail addresses are masked.
2. Group and review (the default path is this project's `user://ops/errors.jsonl`):

   ```bash
   python3 tools/ops/errors_to_issues.py                      # markdown report to stdout
   python3 tools/ops/errors_to_issues.py --out /tmp/errors.md # or to a file
   ```

3. File issues when the report looks right (needs `gh auth login`). The first command prints the `gh` commands; the second runs them:

   ```bash
   python3 tools/ops/errors_to_issues.py --create-issues --min-count 2
   python3 tools/ops/errors_to_issues.py --create-issues --min-count 2 --no-dry-run
   ```

   Issues get the `type/bug` and `from-error-tracker` labels, one per fingerprint. An open issue with the same fingerprint is updated instead of duplicated.
4. Triage new issues: add an `area/*` and `priority/*` label, remove `needs-triage`.
