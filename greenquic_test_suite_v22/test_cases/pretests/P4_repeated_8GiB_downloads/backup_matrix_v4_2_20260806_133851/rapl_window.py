#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import socket
import sys
import time
from typing import Any

POWER_ROOT = Path('/sys/class/powercap')


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding='utf-8').strip()
    except OSError:
        return None


def read_int(path: Path) -> int | None:
    value = read_text(path)
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def discover_domains() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not POWER_ROOT.is_dir():
        return rows

    seen: set[str] = set()
    for name_path in POWER_ROOT.rglob('name'):
        domain = name_path.parent
        energy_path = domain / 'energy_uj'
        if not energy_path.is_file():
            continue
        resolved = str(domain.resolve())
        if resolved in seen:
            continue
        seen.add(resolved)
        domain_name = read_text(name_path) or domain.name
        lowered = domain_name.lower()
        if lowered.startswith('package-') or lowered == 'package':
            kind = 'package'
        elif lowered == 'dram':
            kind = 'dram'
        else:
            continue
        energy_uj = read_int(energy_path)
        max_uj = read_int(domain / 'max_energy_range_uj')
        if energy_uj is None:
            continue
        rows.append({
            'kind': kind,
            'name': domain_name,
            'domain_path': resolved,
            'energy_path': str(energy_path.resolve()),
            'max_energy_range_uj': max_uj,
            'energy_uj': energy_uj,
        })
    rows.sort(key=lambda row: (row['kind'], row['domain_path']))
    return rows


def snapshot(label: str, role: str, mode: str, run_id: str) -> dict[str, Any]:
    return {
        'schema': 'greenquic-p4-aligned-rapl-snapshot-v1',
        'host': socket.gethostname(),
        'pid': os.getpid(),
        'label': label,
        'role': role,
        'mode': mode,
        'run_id': run_id,
        'wall_time_iso': datetime.now(timezone.utc).isoformat(timespec='microseconds'),
        'wall_time_ns': time.time_ns(),
        'monotonic_ns': time.monotonic_ns(),
        'domains': discover_domains(),
    }


def wrapped_delta(start: int, end: int, maximum: int | None) -> int | None:
    if end >= start:
        return end - start
    if maximum is None or maximum <= 0:
        return None
    return (maximum - start) + end


def finish(start: dict[str, Any], end: dict[str, Any]) -> dict[str, Any]:
    start_map = {row['domain_path']: row for row in start.get('domains', [])}
    end_map = {row['domain_path']: row for row in end.get('domains', [])}
    rows: list[dict[str, Any]] = []
    sums = {'package': 0, 'dram': 0}
    valid_counts = {'package': 0, 'dram': 0}

    for path, first in start_map.items():
        last = end_map.get(path)
        if last is None:
            rows.append({**first, 'end_energy_uj': None, 'delta_energy_uj': None, 'valid': False})
            continue
        maximum = first.get('max_energy_range_uj') or last.get('max_energy_range_uj')
        delta = wrapped_delta(int(first['energy_uj']), int(last['energy_uj']), maximum)
        valid = delta is not None and delta >= 0
        row = {
            'kind': first['kind'],
            'name': first['name'],
            'domain_path': path,
            'energy_path': first['energy_path'],
            'max_energy_range_uj': maximum,
            'start_energy_uj': int(first['energy_uj']),
            'end_energy_uj': int(last['energy_uj']),
            'delta_energy_uj': delta,
            'valid': valid,
        }
        rows.append(row)
        if valid:
            sums[first['kind']] += int(delta)
            valid_counts[first['kind']] += 1

    duration_ns = int(end['monotonic_ns']) - int(start['monotonic_ns'])
    duration_s = duration_ns / 1_000_000_000.0 if duration_ns > 0 else None
    package_j = sums['package'] / 1_000_000.0 if valid_counts['package'] else None
    dram_j = sums['dram'] / 1_000_000.0 if valid_counts['dram'] else None
    total_j = None
    if package_j is not None or dram_j is not None:
        total_j = (package_j or 0.0) + (dram_j or 0.0)

    def average(energy: float | None) -> float | None:
        if energy is None or not duration_s or duration_s <= 0:
            return None
        return energy / duration_s

    return {
        'schema': 'greenquic-p4-aligned-rapl-window-v1',
        'host': start.get('host'),
        'label': start.get('label'),
        'role': start.get('role'),
        'mode': start.get('mode'),
        'run_id': start.get('run_id'),
        'start_wall_time_iso': start.get('wall_time_iso'),
        'end_wall_time_iso': end.get('wall_time_iso'),
        'start_wall_time_ns': start.get('wall_time_ns'),
        'end_wall_time_ns': end.get('wall_time_ns'),
        'start_monotonic_ns': start.get('monotonic_ns'),
        'end_monotonic_ns': end.get('monotonic_ns'),
        'duration_s': duration_s,
        'package_domain_count': valid_counts['package'],
        'dram_domain_count': valid_counts['dram'],
        'package_energy_j': package_j,
        'dram_energy_j': dram_j,
        'total_energy_j': total_j,
        'average_package_power_w': average(package_j),
        'average_dram_power_w': average(dram_j),
        'average_total_power_w': average(total_j),
        'valid': bool(duration_s and duration_s > 0 and package_j is not None),
        'domains': rows,
    }


def format_number(value: Any, digits: int = 6) -> str:
    if value is None:
        return 'N/A'
    return f'{float(value):.{digits}f}'


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)

    start_parser = sub.add_parser('start')
    start_parser.add_argument('--state', type=Path, required=True)
    start_parser.add_argument('--label', required=True)
    start_parser.add_argument('--role', choices=('server', 'client'), required=True)
    start_parser.add_argument('--mode', choices=('off', 'basic', 'plus'), required=True)
    start_parser.add_argument('--run-id', required=True)

    finish_parser = sub.add_parser('finish')
    finish_parser.add_argument('--state', type=Path, required=True)
    finish_parser.add_argument('--out', type=Path, required=True)

    args = parser.parse_args()

    if args.command == 'start':
        data = snapshot(args.label, args.role, args.mode, args.run_id)
        args.state.parent.mkdir(parents=True, exist_ok=True)
        args.state.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
        package_count = sum(row['kind'] == 'package' for row in data['domains'])
        dram_count = sum(row['kind'] == 'dram' for row in data['domains'])
        print(
            f"[P4-ALIGNED-RAPL] START role={args.role} mode={args.mode} "
            f"run={args.run_id} package_domains={package_count} dram_domains={dram_count}",
            flush=True,
        )
        return 0

    start_data = json.loads(args.state.read_text(encoding='utf-8'))
    end_data = snapshot(
        str(start_data.get('label', 'P4 aligned RAPL')),
        str(start_data.get('role', 'client')),
        str(start_data.get('mode', 'off')),
        str(start_data.get('run_id', 'unknown')),
    )
    result = finish(start_data, end_data)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(
        f"[P4-ALIGNED-RAPL] FINISH role={result['role']} mode={result['mode']} "
        f"run={result['run_id']} duration_s={format_number(result['duration_s'])} "
        f"package_j={format_number(result['package_energy_j'])} "
        f"dram_j={format_number(result['dram_energy_j'])} "
        f"total_j={format_number(result['total_energy_j'])} "
        f"avg_total_w={format_number(result['average_total_power_w'], 3)} "
        f"valid={1 if result['valid'] else 0}",
        flush=True,
    )
    return 0 if result['valid'] else 3


if __name__ == '__main__':
    raise SystemExit(main())
