# P5 / Performance2 operator command guide

This page collects the Mac-side commands that were useful during the P5 Performance1/Performance2 runs. The commands are intended to be pasted from a Mac terminal while the local checkout is inside the GreenQUIC repository.

The focused Performance2 screen tests these six configurations:

- `baseline`
- `sharded_512`
- `sharded_1024`
- `sharded_2048`
- `rx_prefetch`
- `sharded_rxprefetch`

It first runs only `idle_monitor_normal` and `power_friendly`. The default screening size is 1 repetition × 3 downloads. Use the selected-profile runner later for 6 × 5 validation.

## Start the focused Performance2 Idle + Power screen

This command fetches the current `performance2/p5-max-goodput` branch, extracts both focused-screen wrappers to a temporary directory, and starts V2 detached under `caffeinate`.

```bash
REPO="$(git rev-parse --show-toplevel)"; cd "$REPO"; git fetch origin performance2/p5-max-goodput; TMP="$(mktemp -d)"; P="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"; git show "origin/performance2/p5-max-goodput:$P/mac_run_p2_idle_power_screen.sh" > "$TMP/mac_run_p2_idle_power_screen.sh"; git show "origin/performance2/p5-max-goodput:$P/mac_run_p2_idle_power_screen_v2.sh" > "$TMP/mac_run_p2_idle_power_screen_v2.sh"; chmod +x "$TMP/mac_run_p2_idle_power_screen_v2.sh"; GREENQUIC_REPO="$REPO" P5_P2_RUNS=1 P5_P2_DOWNLOADS=3 bash "$TMP/mac_run_p2_idle_power_screen_v2.sh" --detach
```

Expected startup output includes `STARTED PID=...`, `TAG=...`, and a Mac log path.

## Check the latest Mac-side watcher

```bash
PIDFILE="$(ls -t "$HOME"/Downloads/P5_P2_IDLE_POWER_*.mac.pid 2>/dev/null | head -1)"; PID="$(cat "$PIDFILE" 2>/dev/null)"; LOG="$(ls -t "$HOME"/Downloads/P5_P2_IDLE_POWER_*.mac.log 2>/dev/null | head -1)"; echo "PIDFILE=$PIDFILE"; echo "LOG=$LOG"; ps -p "$PID" -o pid=,ppid=,stat=,etime=,command=; tail -n 60 "$LOG"
```

The Mac watcher may only print `waiting for P2 idle+power screen` once per minute while the detached remote job is healthy.

## Check the actual remote controller and current profile

```bash
ssh idex 'LOG="$(ls -t /root/P5_P2_IDLE_POWER_*.log 2>/dev/null | head -1)"; echo "REMOTE_LOG=$LOG"; echo "=== CONTROLLERS ==="; ps -eo pid=,ppid=,stat=,etime=,args= | grep -E "[r]un_p5_performance2_idle_power_screen|[r]un_matrix_with_sheet|[q]uicinterop|[q]uicinteropserver" || true; echo "=== PROGRESS ==="; grep -E "PROFILE=|IDLE\+POWER|TEST [0-9]+/|MODE=|SUCCESS:|FAILURES=|ERROR:" "$LOG" | tail -60'
```

Seeing a later `PROFILE=...` means the previous configuration has already completed or been attempted, because the focused runner processes configurations sequentially.

## Verify both nodes are on the same commit

```bash
ssh idex 'echo -n "IDEX    "; git -C /root/mohsen rev-parse HEAD; echo -n "TINYMAN "; ssh root@tinyman "git -C /root/mohsen rev-parse HEAD"'
```

Do not infer the active experiment commit from an earlier `git reset --hard` line in a log. Use `rev-parse HEAD` on both hosts.

## Check idex → tinyman SSH directly

```bash
ssh idex 'ssh -o ConnectTimeout=10 root@tinyman "echo IDEX_TO_TINYMAN_OK; hostname"'
```

A transient `No route to host` during bundle copy is recoverable. V2 retries the idex → tinyman copy instead of requiring a manual restart.

## Show completed stages and results so far

```bash
ssh idex 'R="$(ls -td /tmp/P5_P2_IDLE_POWER_SCREEN_* 2>/dev/null | head -1)"; echo "RESULT_ROOT=$R"; echo "=== STATUS ==="; cat "$R/status.env" 2>/dev/null || true; echo "=== GOODPUT SUMMARY SO FAR ==="; if [ -f "$R/idle_power_summary.tsv" ]; then column -t -s $'"'"'\t'"'"' "$R/idle_power_summary.tsv" 2>/dev/null || cat "$R/idle_power_summary.tsv"; fi'
```

For successful stages, expect values such as `..._BUILD_IDEX=0`, `..._BUILD_TINYMAN=0`, and workload `..._RC=0` entries.

`idle_power_summary.tsv` uses aggregate goodput excluding the configured 5-second gaps.

## Show build progress when the main log only says PROFILE=...

The main controller log is intentionally quiet while each host build is running. Use the per-profile build logs:

```bash
ssh idex 'R="$(ls -td /tmp/P5_P2_IDLE_POWER_SCREEN_* 2>/dev/null | head -1)"; echo "RESULT_ROOT=$R"; echo "=== ACTIVE BUILD PROCESSES ==="; ps -eo pid=,ppid=,etime=,args= | grep -E "[b]uild_p5_performance2|[b]uild_p5_super_performance|[c]make --build|[n]inja|[m]ake" || true; echo "=== LATEST BUILD LOGS ==="; for f in $(find "$R/logs" -maxdepth 1 -type f -name "*__build_*.log" -printf "%T@ %p\n" 2>/dev/null | sort -nr | head -2 | cut -d" " -f2-); do echo "--- $f ---"; tail -n 30 "$f"; done'
```

## Follow the newest workload log live

```bash
ssh idex 'R="$(ls -td /tmp/P5_P2_IDLE_POWER_SCREEN_* 2>/dev/null | head -1)"; F="$(find "$R/logs" -maxdepth 1 -type f ! -name "*__build_*.log" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d" " -f2-)"; echo "LIVE_LOG=$F"; [ -n "$F" ] && tail -f "$F"'
```

`Ctrl-C` stops only `tail -f`; it does not stop the detached experiment.

## Quick active-process check on both machines

```bash
ssh idex 'echo "=== IDEX ==="; ps -eo pid=,ppid=,etime=,args= | grep -E "[r]un_p5_performance2|[r]un_matrix_with_sheet|[q]uicinterop|[q]uicinteropserver" || true; echo "=== TINYMAN ==="; ssh root@tinyman '"'"'ps -eo pid=,ppid=,etime=,args= | grep -E "[r]un_matrix_with_sheet|[q]uicinterop|[q]uicinteropserver" || true'"'"''
```

If this prints no matching processes on either host, no P5/P2 worker from these patterns is active.

## Check whether the remote screen is finished

```bash
ssh idex 'D="$(ls -td /tmp/P5_P2_IDLE_POWER_EXPORT_* 2>/dev/null | head -1)"; echo "REMOTE_EXPORT=$D"; if [ -n "$D" ] && [ -f "$D/DONE" ]; then echo REMOTE_DONE; else echo REMOTE_NOT_DONE; fi'
```

`REMOTE_DONE` means the remote experiment/export stage finished. The Mac watcher may still be copying and SHA256-verifying files.

## Check whether the verified copy reached the Mac

```bash
D="$(ls -td "$HOME"/Downloads/P5_P2_IDLE_POWER_EXPORT_* 2>/dev/null | head -1)"; echo "LOCAL_EXPORT=$D"; if [ -n "$D" ] && [ -f "$D/SCP_DONE" ]; then echo SCP_VERIFIED_COMPLETE; cat "$D/SCP_DONE"; else echo SCP_NOT_COMPLETE; fi
```

`SCP_DONE` is the final local completion marker after SHA256 verification.

## Inspect downloaded result files

```bash
D="$(ls -td "$HOME"/Downloads/P5_P2_IDLE_POWER_EXPORT_* 2>/dev/null | head -1)"; echo "$D"; ls -lh "$D"; echo; cat "$D/result_rc.txt" 2>/dev/null || true; echo; cat "$D/status.env" 2>/dev/null || true; echo; column -t -s $'\t' "$D/idle_power_summary.tsv" 2>/dev/null || cat "$D/idle_power_summary.tsv" 2>/dev/null || true
```

The export normally contains the analysis ZIP, full matrix ZIP, `idle_power_summary.tsv`, `status.env`, `result_rc.txt`, `remote.log`, `SHA256SUMS`, and `SCP_DONE` after copy completion.

## Inspect a stale Mac PID before killing it

Never kill a PID only because an old PID file exists; the PID may have been reused. First inspect it:

```bash
PF="$(ls -t "$HOME"/Downloads/P5_P1_P2_CHAIN_V*.pid "$HOME"/Downloads/P5_P2_IDLE_POWER_*.mac.pid 2>/dev/null | head -1)"; PID="$(cat "$PF" 2>/dev/null)"; echo "PIDFILE=$PF"; ps -p "$PID" -o pid=,ppid=,stat=,etime=,command=
```

If the command shown by `ps` is definitely the stale GreenQUIC Mac orchestrator, terminate it gracefully first:

```bash
kill -TERM "$PID"; sleep 2; ps -p "$PID" -o pid=,stat=,command= 2>/dev/null || echo "PID $PID gone"
```

Killing a Mac watcher does not necessarily kill a detached remote experiment. Always run the remote process check before starting another screen.

## Important operating rules

- Do not start a second P1/P2 screen while an existing controller or matrix run is active.
- Do not use `pkill -f` for cleanup; it can kill the controller that is performing the cleanup.
- Do not delete `/var/run/dpdk/rte` while a process still holds the DPDK runtime files.
- Keep the long experiment detached (`nohup`/`setsid`) and keep the Mac awake with `caffeinate`.
- Treat `SCP_DONE` as local transfer completion, not merely the presence of ZIP files.
- For repeated-download P5 goodput, use the aggregate goodput excluding gaps from the P5 workload summary/all-runs table, not the legacy generic 40-GiB whole-duration summary.
- For final Performance2 conclusions, compare the selected configuration under the same external profiles as Performance1; do not infer final behavior from a single screening workload.
