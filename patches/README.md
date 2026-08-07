# Patch and debug archive

This directory contains historical one-off patch scripts, tracked-change snapshots, and debugging captures that used to clutter the repository root.

These files are retained for provenance and troubleshooting. They are **not** part of the current GreenQUIC bootstrap/runtime path.

Active root entry points intentionally remain at repository root, including:

- `bootstrap_greenquic.sh`
- `bootstrap_greenquic_core.sh`
- `run_greenquic_v22.sh`
- `prepare_test_payloads.sh`
- `greenquic_autopatch*.py`
- `acpi.sh`
- `SOURCE_STATE.txt`

Historical shell patches live under `patches/legacy/`; debugger and node-info captures live under `patches/debug/`.
