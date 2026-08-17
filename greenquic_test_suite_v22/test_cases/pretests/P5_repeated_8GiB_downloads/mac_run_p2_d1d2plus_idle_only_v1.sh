#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
SOURCE="$HERE/mac_run_p2_final_6x6_d1d2plus_p7_paper_v1.sh"
[[ -f "$SOURCE" ]] || { echo "ERROR: missing D1/D2+ Mac orchestrator: $SOURCE" >&2; exit 2; }

# Create a temporary copy of the existing, battle-tested Mac orchestrator and
# add only one behavior: run P5 Idle Monitor, while skipping Power Friendly and
# P7. All normal orchestration remains intact: clean/preflight, exact branch
# bundle to both nodes, D1/D2+ build/marker checks, detached remote execution,
# report generation, ZIP/SHA256 export and SCP back to the Mac.
TAG="$(date +%Y%m%d_%H%M%S)_$$"
PATCHED="${TMPDIR:-/tmp}/mac_run_p2_d1d2plus_idle_only_${TAG}.sh"
cleanup(){ rm -f -- "$PATCHED"; }
trap cleanup EXIT INT TERM

python3 - "$SOURCE" "$PATCHED" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding='utf-8')
needle = 'Path(sys.argv[2]).write_text(src)\nPY\n'
if src.count(needle) != 1:
    raise SystemExit(f'ERROR: idle-only patch anchor expected once, got {src.count(needle)}')

inject = r'''
# Dedicated P5 Idle-only orchestration mode. This patch is baked into the
# generated base runner before its --detach re-exec, so no extra environment
# variable needs to survive the base runner's detached env whitelist.
if os.environ.get('P5_D1D2PLUS_IDLE_ONLY','0').lower() in ('1','true','yes','on'):
    # 1) Skip Power Friendly but report success so normal export/finalization runs.
    power_old='''    echo '=== 2/3 P5 POWER_FRIENDLY — OFF/BASIC/PLUS ==='\n    run_p5 "$PWR" \\\n        --env ENABLE_FREQ=1 \\\n        --env ENABLE_SLEEP=1 \\\n        --env GQ_IDLE_MODE_OVERRIDE=epoll \\\n        --env GQ_IDLE_FALLBACK_OVERRIDE=short\n    RC2=$?\n    echo "P5 POWER_FRIENDLY RC=$RC2"\n'''
    power_new='''    echo '=== 2/3 P5 POWER_FRIENDLY — SKIPPED (P5 D1/D2+ Idle-only) ==='\n    RC2=0\n    echo "P5 POWER_FRIENDLY RC=$RC2 (SKIPPED_IDLE_ONLY)"\n'''
    if src.count(power_old) != 1:
        raise SystemExit(f'ERROR: idle-only power block expected once, got {src.count(power_old)}')
    src=src.replace(power_old,power_new,1)

    # 2) Do not waste time building Linux/P7 binaries.
    p7_build_old='''# Build the isolated normal-Linux P7 binaries on both endpoints before measurement.\necho '=== BUILD P7 LINUX ==='\n(cd "$P7" && bash ./build_p7_linux.sh >"$EX/build_p7_idex.log" 2>&1) & p3=$!\nssh -n root@tinyman "cd '$P7' && bash ./build_p7_linux.sh" >"$EX/build_p7_tinyman.log" 2>&1 & p4=$!\nwait "$p3"; BP71=$?\nwait "$p4"; BP72=$?\necho "P7 builds: idex=$BP71 tinyman=$BP72"\n'''
    p7_build_new='''# P7 intentionally skipped in P5 D1/D2+ Idle-only mode.\nBP71=0; BP72=0\nprintf '%s\\n' 'SKIPPED: P7 build (P5 D1/D2+ Idle-only)' >"$EX/build_p7_idex.log"\nprintf '%s\\n' 'SKIPPED: P7 build (P5 D1/D2+ Idle-only)' >"$EX/build_p7_tinyman.log"\necho "P7 builds: idex=0 tinyman=0 (SKIPPED_IDLE_ONLY)"\n'''
    if src.count(p7_build_old) != 1:
        raise SystemExit(f'ERROR: idle-only P7 build block expected once, got {src.count(p7_build_old)}')
    src=src.replace(p7_build_old,p7_build_new,1)

    # 3) Skip the P7 matrix itself. Locate the complete block after the D1/D2+
    # transformations, rather than duplicating all of its paper arguments here.
    p7_start='if [ "$BP71" -eq 0 ] && [ "$BP72" -eq 0 ]; then\n'
    p7_end='    echo "P7 LINUX RC=$RC3"\nelse\n    echo \'ERROR: P7 build failed; P7 matrix skipped.\'\nfi\n'
    a=src.find(p7_start)
    if a < 0:
        raise SystemExit('ERROR: idle-only P7 run start anchor missing')
    b=src.find(p7_end,a)
    if b < 0:
        raise SystemExit('ERROR: idle-only P7 run end anchor missing')
    b += len(p7_end)
    p7_skip='''echo '=== 3/3 P7 PAPER + D1/D2+ — SKIPPED (P5 Idle-only) ==='\nRC3=0\necho "P7 LINUX RC=$RC3 (SKIPPED_IDLE_ONLY)"\n'''
    src=src[:a]+p7_skip+src[b:]

    src=src.replace('P2 FINAL startup tag=', 'P2 D1D2+ IDLE-ONLY startup tag=',1)
'''

src = src.replace(needle, inject + '\nPath(sys.argv[2]).write_text(src)\nPY\n', 1)
Path(sys.argv[2]).write_text(src, encoding='utf-8')
PY

chmod 0700 "$PATCHED"
bash -n "$PATCHED"

unset P5_D1D2PLUS_SMOKE_IDLE_P7_ONLY
export P5_D1D2PLUS_IDLE_ONLY=1
exec bash "$PATCHED" "$@"
