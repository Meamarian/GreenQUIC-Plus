#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
from pathlib import Path

LCORE_RE = re.compile(
    r'\[GreenQUIC-MC\] LCORE_STATS[^\n]*lcore=(\d+)[^\n]*rxq=(\d+)[^\n]*txq=(\d+)'
    r'[^\n]*owns_rx=(\d+)[^\n]*owns_tx=(\d+)[^\n]*rx_pkts=(\d+)'
    r'[^\n]*tx_pkts=(\d+)[^\n]*total_pkts=(\d+)'
)
QUEUE_RE = re.compile(
    r'\[GreenQUIC-MC\] QUEUE_STATS[^\n]*rxq0=(\d+)[^\n]*rxq1=(\d+)'
    r'[^\n]*txq0=(\d+)[^\n]*txq1=(\d+)[^\n]*tx_hash_fallback=(\d+)'
)
ROLE_RE = re.compile(r'GreenQUIC roles: lcores=(\d+) rx_owners=(\d+) rxq=(\d+)')


def one(root: Path, pattern: str) -> Path:
    rows = list(root.rglob(pattern))
    if len(rows) != 1:
        raise RuntimeError(f'expected exactly one {pattern} under {root}, found {len(rows)}')
    return rows[0]


def read_rapl(path: Path) -> list[dict[str, float]]:
    lines = [x for x in path.read_text(encoding='utf-8', errors='replace').splitlines() if x and not x.startswith('#')]
    out: list[dict[str, float]] = []
    for row in csv.DictReader(lines):
        try:
            out.append({k: float(v) for k, v in row.items() if k and v not in (None, '')})
        except ValueError:
            continue
    return out


def rapl_metrics(rows: list[dict[str, float]], start_ns: int, end_ns: int) -> dict[str, float]:
    pkg = dram = 0.0
    samples = 0
    for row in rows:
        try:
            sample_end = int(row['sample_monotonic_ns'])
            interval_ns = max(1, int(row['actual_interval_ms'] * 1_000_000.0))
        except (KeyError, TypeError, ValueError):
            continue
        sample_start = sample_end - interval_ns
        a = max(sample_start, start_ns)
        b = min(sample_end, end_ns)
        if b <= a:
            continue
        frac = (b - a) / interval_ns
        pkg += row.get('package_delta_j', 0.0) * frac
        dram += row.get('dram_delta_j', 0.0) * frac
        samples += 1
    duration = (end_ns - start_ns) / 1e9
    if samples == 0 or duration <= 0:
        return {'samples': 0, 'package_j': 0.0, 'dram_j': 0.0, 'total_j': 0.0, 'avg_total_w': 0.0}
    total = pkg + dram
    return {'samples': samples, 'package_j': pkg, 'dram_j': dram, 'total_j': total, 'avg_total_w': total / duration}


def read_busy(path: Path) -> dict[int, list[tuple[int, int, int]]]:
    by: dict[int, list[tuple[int, int, int]]] = {}
    with path.open(newline='', encoding='utf-8') as f:
        for row in csv.DictReader(f):
            try:
                cpu = int(row['cpu'])
                item = (int(row['monotonic_ns']), int(row['busy_jiffies']), int(row['total_jiffies']))
            except (KeyError, TypeError, ValueError):
                continue
            by.setdefault(cpu, []).append(item)
    for cpu in by:
        by[cpu].sort()
    return by


def busy_window(samples: list[tuple[int, int, int]], start_ns: int, end_ns: int) -> float | None:
    if len(samples) < 2:
        return None
    before = None
    after = None
    for row in samples:
        if row[0] <= start_ns:
            before = row
        if row[0] >= end_ns:
            after = row
            break
    if before is None:
        before = samples[0]
    if after is None:
        after = samples[-1]
    db = after[1] - before[1]
    dt = after[2] - before[2]
    if dt <= 0 or db < 0:
        return None
    return max(0.0, min(100.0, 100.0 * db / dt))


def parse_last_stats(path: Path) -> tuple[list[dict], dict, dict]:
    text = path.read_text(encoding='utf-8', errors='replace')
    lcores = []
    for m in LCORE_RE.finditer(text):
        lcores.append({
            'lcore': int(m.group(1)), 'rxq': int(m.group(2)), 'txq': int(m.group(3)),
            'owns_rx': int(m.group(4)), 'owns_tx': int(m.group(5)),
            'rx_pkts': int(m.group(6)), 'tx_pkts': int(m.group(7)), 'total_pkts': int(m.group(8)),
        })
    # Keep the last record for each lcore. Shutdown should emit one set.
    by_lcore = {r['lcore']: r for r in lcores}
    qmatches = list(QUEUE_RE.finditer(text))
    q = {}
    if qmatches:
        m = qmatches[-1]
        q = {'rxq0': int(m.group(1)), 'rxq1': int(m.group(2)), 'txq0': int(m.group(3)), 'txq1': int(m.group(4)), 'tx_hash_fallback': int(m.group(5))}
    rmatches = list(ROLE_RE.finditer(text))
    roles = {}
    if rmatches:
        m = rmatches[-1]
        roles = {'configured_lcores': int(m.group(1)), 'rx_owners': int(m.group(2)), 'rx_queues': int(m.group(3))}
    return [by_lcore[k] for k in sorted(by_lcore)], q, roles


def mean_sd(vals: list[float]) -> tuple[float, float]:
    if not vals:
        return 0.0, 0.0
    return statistics.mean(vals), statistics.stdev(vals) if len(vals) > 1 else 0.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--case-dir', type=Path, required=True)
    ap.add_argument('--case-name', required=True)
    ap.add_argument('--runs', type=int, required=True)
    ap.add_argument('--connections', type=int, required=True)
    ap.add_argument('--dpdk-cpus', default='19,20')
    ap.add_argument('--all-cpus', default='19,20,21,22,23,24')
    args = ap.parse_args()

    root = args.case_dir.resolve()
    dpdk_cpus = [int(x) for x in args.dpdk_cpus.split(',') if x]
    all_cpus = [int(x) for x in args.all_cpus.split(',') if x]
    server_busy = read_busy(root / 'cpu_busy_server.csv')
    client_busy = read_busy(root / 'cpu_busy_client.csv')
    rows: list[dict] = []
    lcore_rows: list[dict] = []

    for rep in range(1, args.runs + 1):
        run_id = f'rep{rep:02d}_off'
        croot = root / 'runs' / 'client' / run_id
        sroot = root / 'runs' / 'server' / run_id
        metrics = json.loads(one(croot, '*p5_parallel_metrics_*.json').read_text(encoding='utf-8'))
        conns = metrics.get('connections', [])
        if int(metrics.get('quic_connections', 0)) != args.connections or len(conns) != args.connections:
            raise SystemExit(f'ERROR: invalid connection metrics for {run_id}')
        cstart = int(metrics['batch_start_us']) * 1000
        cend = int(metrics['batch_complete_us']) * 1000
        sync = json.loads((root / f'clock_sync_{run_id}.json').read_text(encoding='utf-8'))
        offset = int(sync['client_minus_controller_monotonic_offset_ns'])
        sstart, send = cstart - offset, cend - offset

        cr = rapl_metrics(read_rapl(one(croot, '*_msr_power.csv')), cstart, cend)
        sr = rapl_metrics(read_rapl(one(sroot, '*_msr_power.csv')), sstart, send)
        server_log = root / f'server_{run_id}.log'
        client_log = root / f'client_{run_id}.log'
        sl, sq, sroles = parse_last_stats(server_log)
        cl, cq, croles = parse_last_stats(client_log)

        row = {
            'case': args.case_name,
            'repetition': rep,
            'connections': args.connections,
            'dpdk_cpus': ';'.join(map(str, dpdk_cpus)),
            'active_duration_s': (cend - cstart) / 1e9,
            'aggregate_goodput_gbps': float(metrics['aggregate_goodput_gbps']),
            'mean_connection_goodput_gbps': statistics.mean(float(x['goodput_gbps']) for x in conns),
            'server_rapl_w': sr['avg_total_w'],
            'client_rapl_w': cr['avg_total_w'],
            'combined_rapl_w': sr['avg_total_w'] + cr['avg_total_w'],
            'server_rapl_j': sr['total_j'],
            'client_rapl_j': cr['total_j'],
            'combined_rapl_j': sr['total_j'] + cr['total_j'],
            'server_configured_lcores': sroles.get('configured_lcores', ''),
            'client_configured_lcores': croles.get('configured_lcores', ''),
            'server_tx_hash_fallback': sq.get('tx_hash_fallback', ''),
            'client_tx_hash_fallback': cq.get('tx_hash_fallback', ''),
        }
        for idx, conn in enumerate(conns, 1):
            row[f'conn{idx}_goodput_gbps'] = float(conn['goodput_gbps'])
            row[f'conn{idx}_duration_s'] = int(conn['duration_us']) / 1e6
        for role, by, a, b in (
            ('server', server_busy, sstart, send),
            ('client', client_busy, cstart, cend),
        ):
            for cpu in all_cpus:
                val = busy_window(by.get(cpu, []), a, b)
                row[f'{role}_cpu{cpu}_busy_pct'] = '' if val is None else val
        for role, vals in (('server', sl), ('client', cl)):
            total = sum(x['total_pkts'] for x in vals)
            for x in vals:
                item = {'case': args.case_name, 'repetition': rep, 'role': role, **x}
                item['packet_share_pct'] = 100.0 * x['total_pkts'] / total if total else 0.0
                item['engaged'] = int(x['total_pkts'] > 0)
                lcore_rows.append(item)
                row[f'{role}_lcore{x["lcore"]}_rx_pkts'] = x['rx_pkts']
                row[f'{role}_lcore{x["lcore"]}_tx_pkts'] = x['tx_pkts']
                row[f'{role}_lcore{x["lcore"]}_total_pkts'] = x['total_pkts']
                row[f'{role}_lcore{x["lcore"]}_packet_share_pct'] = item['packet_share_pct']
        rows.append(row)

    tables = root / 'bottleneck_tables'
    tables.mkdir(parents=True, exist_ok=True)
    all_csv = tables / 'case_metrics.csv'
    fields = sorted({k for r in rows for k in r}, key=lambda x: (x not in ('case', 'repetition', 'aggregate_goodput_gbps'), x))
    with all_csv.open('w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader(); w.writerows(rows)

    lc_csv = tables / 'lcore_activity.csv'
    if lcore_rows:
        with lc_csv.open('w', newline='', encoding='utf-8') as f:
            w = csv.DictWriter(f, fieldnames=list(lcore_rows[0]))
            w.writeheader(); w.writerows(lcore_rows)

    measures = ['aggregate_goodput_gbps', 'mean_connection_goodput_gbps', 'server_rapl_w', 'client_rapl_w', 'combined_rapl_w']
    measures += [f'{role}_cpu{cpu}_busy_pct' for role in ('server', 'client') for cpu in all_cpus]
    summary = {
        'schema': 'greenquic-p5-bottleneck-case-v1',
        'case': args.case_name,
        'runs': args.runs,
        'connections': args.connections,
        'dpdk_cpus': dpdk_cpus,
    }
    for key in measures:
        vals = [float(r[key]) for r in rows if r.get(key) not in ('', None)]
        mean, sd = mean_sd(vals)
        summary[f'{key}_mean'] = mean
        summary[f'{key}_stdev'] = sd
    summary['all_configured_dpdk_lcores_engaged'] = all(
        any(x['role'] == role and x['repetition'] == rep and x['lcore'] == cpu and x['engaged'] for x in lcore_rows)
        for role in ('server', 'client') for rep in range(1, args.runs + 1) for cpu in dpdk_cpus
    )
    summary['tx_hash_fallback_total'] = sum(int(r.get('server_tx_hash_fallback') or 0) + int(r.get('client_tx_hash_fallback') or 0) for r in rows)
    (tables / 'case_summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    with (tables / 'case_summary.csv').open('w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=list(summary))
        w.writeheader(); w.writerow(summary)

    print(f"BOTTLENECK CASE {args.case_name}: goodput={summary['aggregate_goodput_gbps_mean']:.6f} Gbit/s "
          f"SD={summary['aggregate_goodput_gbps_stdev']:.6f} combined_RAPL={summary['combined_rapl_w_mean']:.3f} W "
          f"dpdk_engaged={int(bool(summary['all_configured_dpdk_lcores_engaged']))}")
    for role in ('server', 'client'):
        print('  ' + role + ' busy: ' + ' '.join(
            f"CPU{cpu}={summary.get(f'{role}_cpu{cpu}_busy_pct_mean', 0.0):.1f}%" for cpu in all_cpus
        ))
    print(f'CASE METRICS: {all_csv}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
