# Gate or CI failure

## Symptoms

`tools/gate.sh quick|full` prints `FAIL` for a step, or the `gate-quick` / `lint` CI job is red.

## Confirm

1. Re-run only the failing step locally and keep its temp user dir:

   ```bash
   tools/gate.sh quick --only fp_traffic --keep
   ```

2. Logs are in the printed `GATE_LOG_DIR` (default `/tmp/claude-1000/gf-gate-<branch>-<ts>/`), one file per step, plus `results.json` with the result and seconds per step. On CI they are the `gate-logs` artifact.
3. With `GATE_RETRIES=1` (CI default) a failed step is re-run once; a step that passes on the retry is recorded in `flaky.txt` in the log dir. `python tools/checks/flaky_report.py <log dir>` lists them.

## Fix

- **Parse errors (`parse_all`):** the log names the script and line. Usually a typo or a renamed `class_name`.
- **Missing resource / null instance after asset changes:** run the asset re-import ([asset-import.md](asset-import.md)), then re-run.
- **Test expectations broken by a deliberate change:** update the test in the same commit and say why in the PR.
- **Timeouts on CI only:** the runner is slower and imports assets cold when the `.godot` cache misses. The job summary compares step times with the last green `main` run (`tools/checks/build_timing.py`); raise `GATE_IMPORT_TIMEOUT` only if the import itself grew.
- **A step hangs (`TIMEOUT` well past its usual time):** the gate stops it with SIGSEGV, so the end of the step log holds Godot's C++ and GDScript backtraces. The GDScript one names the script line the main thread was stuck on.
- **`fp_bench` rows with `FPBENCH: WARNING ... drew N of M frames`:** the window stopped drawing (minimised, on another workspace, or the screen locked) while frames kept running, so those rows measure an idle loop. Keep the bench window visible and re-run. Shots it could not take are skipped after 5 s instead of hanging the step.
- **Repo checks (`checks` job):** run `python tools/checks/run_all.py -v`. Only findings beyond `tools/checks/baselines/` fail; fix the new finding rather than editing the baseline.
- **Flaky test:** fix the race (usually waiting a fixed number of frames) and open an issue labelled `flaky` until it is fixed.

## Verify

`tools/gate.sh quick` exits 0 and the CI re-run is green.
