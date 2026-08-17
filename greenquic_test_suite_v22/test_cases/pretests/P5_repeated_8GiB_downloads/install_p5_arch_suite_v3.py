#!/usr/bin/env python3
from __future__ import annotations
import argparse,base64,io,tarfile
from pathlib import Path
HERE=Path(__file__).resolve().parent

def main():
    ap=argparse.ArgumentParser();ap.add_argument("--target",type=Path,required=True);a=ap.parse_args()
    target=a.target.resolve();target.mkdir(parents=True,exist_ok=True)
    payload=(HERE/"p5_arch_payload_1.txt").read_text().strip()+(HERE/"p5_arch_payload_2.txt").read_text().strip()
    raw=base64.b64decode(payload,validate=True);count=0
    with tarfile.open(fileobj=io.BytesIO(raw),mode="r:gz") as tf:
        for member in tf.getmembers():
            if not member.isfile() or "/" in member.name or member.name.startswith("."):
                raise SystemExit(f"ERROR unsafe architecture payload member: {member.name}")
            src=tf.extractfile(member)
            if src is None: raise SystemExit(f"ERROR cannot extract {member.name}")
            p=target/member.name;p.write_bytes(src.read());p.chmod(0o755);count+=1;print(f"P5_ARCH_INSTALL {p}")
    print(f"P5_ARCH_INSTALL_PASS files={count} target={target}")
if __name__=="__main__":main()
