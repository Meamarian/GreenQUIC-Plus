#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path


def pct(v: float, base: float) -> float:
    return ((v / base) - 1.0) * 100.0 if base else 0.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', type=Path, required=True)
    args = ap.parse_args()
    root = args.root.resolve()
    rows = []
    for case_dir in sorted(p for p in root.iterdir() if p.is_dir() and p.name[:2] in {f'{c}_' for c in 'ABCDEFGHIJ'}):
        summary = case_dir / 'bottleneck_tables' / 'case_summary.json'
        cfg = case_dir / 'BOTTLENECK_CASE_CONFIG.env'
        if not summary.is_file():
            rows.append({'case': case_dir.name, 'status': 'MISSING_OR_FAILED'})
            continue
        j = json.loads(summary.read_text(encoding='utf-8'))
        rows.append({
            'case': j['case'],
            'status': 'PASS',
            'runs': j['runs'],
            'connections': j['connections'],
            'dpdk_cpus': ';'.join(map(str, j['dpdk_cpus'])),
            'mean_goodput_gbps': j['aggregate_goodput_gbps_mean'],
            'stdev_goodput_gbps': j['aggregate_goodput_gbps_stdev'],
            'combined_rapl_w': j['combined_rapl_w_mean'],
            'server_cpu19_busy_pct': j.get('server_cpu19_busy_pct_mean', 0.0),
            'server_cpu20_busy_pct': j.get('server_cpu20_busy_pct_mean', 0.0),
            'client_cpu19_busy_pct': j.get('client_cpu19_busy_pct_mean', 0.0),
            'client_cpu20_busy_pct': j.get('client_cpu20_busy_pct_mean', 0.0),
            'server_cpu21_busy_pct': j.get('server_cpu21_busy_pct_mean', 0.0),
            'server_cpu22_busy_pct': j.get('server_cpu22_busy_pct_mean', 0.0),
            'server_cpu23_busy_pct': j.get('server_cpu23_busy_pct_mean', 0.0),
            'server_cpu24_busy_pct': j.get('server_cpu24_busy_pct_mean', 0.0),
            'client_cpu21_busy_pct': j.get('client_cpu21_busy_pct_mean', 0.0),
            'client_cpu22_busy_pct': j.get('client_cpu22_busy_pct_mean', 0.0),
            'client_cpu23_busy_pct': j.get('client_cpu23_busy_pct_mean', 0.0),
            'client_cpu24_busy_pct': j.get('client_cpu24_busy_pct_mean', 0.0),
            'all_configured_dpdk_lcores_engaged': int(bool(j.get('all_configured_dpdk_lcores_engaged'))),
            'tx_hash_fallback_total': j.get('tx_hash_fallback_total', 0),
            'config_file': str(cfg) if cfg.is_file() else '',
        })

    passed = [r for r in rows if r.get('status') == 'PASS']
    by = {r['case']: r for r in passed}
    one = by.get('A_1c_baseline')
    two = by.get('B_2c_baseline')
    for r in passed:
        r['delta_vs_1c_pct'] = pct(float(r['mean_goodput_gbps']), float(one['mean_goodput_gbps'])) if one else ''
        r['delta_vs_2c_baseline_pct'] = pct(float(r['mean_goodput_gbps']), float(two['mean_goodput_gbps'])) if two else ''
        delta = r['delta_vs_2c_baseline_pct'] if r['delta_vs_2c_baseline_pct'] != '' else 0.0
        if r['case'] == 'A_1c_baseline':
            r['effect_class'] = 'reference'
        elif r['case'] == 'B_2c_baseline':
            r['effect_class'] = 'core-scaling reference'
        elif delta >= 3.0:
            r['effect_class'] = 'material positive'
        elif delta <= -3.0:
            r['effect_class'] = 'material negative'
        else:
            r['effect_class'] = 'no material change (<3%)'

    out_csv = root / 'BOTTLENECK_SWEEP_SUMMARY.csv'
    fields = []
    for r in rows:
        for k in r:
            if k not in fields:
                fields.append(k)
    with out_csv.open('w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader(); w.writerows(rows)

    ranked = sorted(passed, key=lambda r: float(r['mean_goodput_gbps']), reverse=True)
    txt = []
    txt.append('P5 BOTTLENECK SWEEP SUMMARY')
    txt.append('All cases: OFF mode, 4 simultaneous 8GiB QUIC connections, identical run count.')
    txt.append('A->B isolates DPDK core-count scaling. C-J are controlled design perturbations.')
    txt.append('')
    txt.append('case                         goodput    SD       vs1c      vs2c      power     DPDK engaged  effect')
    for r in rows:
        if r.get('status') != 'PASS':
            txt.append(f"{r['case']:<28} FAILED/MISSING")
            continue
        d1 = r.get('delta_vs_1c_pct', '')
        d2 = r.get('delta_vs_2c_baseline_pct', '')
        txt.append(
            f"{r['case']:<28} {float(r['mean_goodput_gbps']):>8.4f}  {float(r['stdev_goodput_gbps']):>7.4f}  "
            f"{float(d1):>+7.2f}%  {float(d2):>+7.2f}%  {float(r['combined_rapl_w']):>8.2f}W  "
            f"{r['all_configured_dpdk_lcores_engaged']}             {r['effect_class']}"
        )
    txt.append('')
    if one and two:
        core_delta = pct(float(two['mean_goodput_gbps']), float(one['mean_goodput_gbps']))
        txt.append(f"Core scaling A->B: {core_delta:+.3f}%")
        if abs(core_delta) < 3.0:
            txt.append('Interpretation flag: adding the second DPDK lcore did not materially raise goodput.')
        elif core_delta > 0:
            txt.append('Interpretation flag: DPDK core scaling materially raised goodput.')
        else:
            txt.append('Interpretation flag: the second DPDK lcore reduced goodput materially.')
    if ranked:
        txt.append(f"Best observed case: {ranked[0]['case']} = {float(ranked[0]['mean_goodput_gbps']):.6f} Gbit/s")
    positives = [r for r in passed if r.get('effect_class') == 'material positive']
    if positives:
        txt.append('Material positive perturbations vs B: ' + ', '.join(r['case'] for r in positives))
    else:
        txt.append('Material positive perturbations vs B: none at the 3% threshold.')
    txt.append('')
    txt.append('CPU busy columns and per-case lcore_activity.csv must be inspected before assigning causality.')
    out_txt = root / 'BOTTLENECK_SWEEP_SUMMARY.txt'
    out_txt.write_text('\n'.join(txt) + '\n', encoding='utf-8')
    print(out_txt.read_text(encoding='utf-8'), end='')
    print(f'CSV: {out_csv}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
