\
#!/usr/bin/env python3
from __future__ import annotations
import argparse, re
from pathlib import Path
KEYS = (
    "SERVER_HOST", "SERVER_LISTEN", "SERVER_PORT",
    "SERVER_LOCAL_IP", "CLIENT_LOCAL_IP",
    "SERVER_LOCAL_MAC", "CLIENT_LOCAL_MAC",
    "SERVER_PEER_MAC", "CLIENT_PEER_MAC",
    "SERVER_DPDK_DEVICE", "CLIENT_DPDK_DEVICE",
    "SERVER_DPDK_LCORES", "CLIENT_DPDK_LCORES",
    "SERVER_QUIC_CPUS", "CLIENT_QUIC_CPUS",
    "SERVER_PARTITION_MAP", "CLIENT_PARTITION_MAP",
    "SERVER_TX_OWNER_LCORE", "CLIENT_TX_OWNER_LCORE",
    "GREENQUIC_DPDK_DRIVER_PATH",
)
PAT = re.compile(r'^([A-Z0-9_]+)=')
def assignment_map(path: Path) -> dict[str,str]:
    out={}
    for line in path.read_text(encoding='utf-8').splitlines():
        m=PAT.match(line.strip())
        if m and m.group(1) in KEYS: out[m.group(1)] = line
    return out

def main() -> int:
    ap=argparse.ArgumentParser(); ap.add_argument('--old',type=Path,required=True); ap.add_argument('--new',type=Path,required=True); args=ap.parse_args()
    if not args.old.is_file(): print(f'No old suite.env to import: {args.old}'); return 0
    old=assignment_map(args.old); lines=args.new.read_text(encoding='utf-8').splitlines(); changed=[]; result=[]
    for line in lines:
        m=PAT.match(line.strip())
        if m and m.group(1) in old:
            key=m.group(1); result.append(old[key]); changed.append(key)
        else: result.append(line)
    args.new.write_text('\n'.join(result)+'\n',encoding='utf-8')
    print('Imported host/NIC identity keys:', ', '.join(changed) if changed else 'none')
    return 0
if __name__=='__main__': raise SystemExit(main())
