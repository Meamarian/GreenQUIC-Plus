#!/usr/bin/env python3
"""Strict validation for GreenQUIC V22 dpdk.ini and powermng.ini."""
from __future__ import annotations
import argparse, hashlib, json, re, sys
from pathlib import Path

TOPOLOGY_KEYS = {
    "DeviceName", "GreenQuicMode", "GreenQuicProfile", "GreenQuicQuicProfile",
    "GreenQuicDpdkLcore", "GreenQuicDpdkLcores", "GreenQuicEnableMultiCore",
    "GreenQuicQuicWorkerCpus", "GreenQuicPartitionDpdkMap",
    "GreenQuicTxOwnerLcore", "GreenQuicTxOwnerAlsoRx",
    "GreenQuicEnableRx", "GreenQuicEnableTx", "GreenQuicQuicAffinitize",
    "LocalIp", "PeerMac", "DpdkInitArgs",
}
V18_POWER_KEYS = {
    "GreenQuicEnableFreq", "GreenQuicEnableSleep",
    "GreenQuicNoSleepIfTxRingNotEmpty", "GreenQuicTxRingProtectUp",
    "GreenQuicPressureScale", "GreenQuicPressureMaxThreshold",
    "GreenQuicPressureUpThreshold", "GreenQuicPressureKeepThreshold",
    "GreenQuicRxQueueHigh", "GreenQuicRxQueueSamplePeriod", "GreenQuicTxRingHigh",
    "GreenQuicRxBurstRiseAlphaPermille", "GreenQuicRxBurstFallAlphaPermille",
    "GreenQuicRxQueueRiseAlphaPermille", "GreenQuicRxQueueFallAlphaPermille",
    "GreenQuicTxBurstRiseAlphaPermille", "GreenQuicTxBurstFallAlphaPermille",
    "GreenQuicTxRingRiseAlphaPermille", "GreenQuicTxRingFallAlphaPermille",
    "GreenQuicFullBurstMaxCount", "GreenQuicFullBurstFloor",
    "GreenQuicAckClientFloor", "GreenQuicAckOtherFloor",
    "GreenQuicAckRxHardMaxThreshold", "GreenQuicEnableAckRxHardMax",
    "GreenQuicAckBlocksSleep", "GreenQuicCwndGrowthNoWorkFloor",
    "GreenQuicCwndGrowthWorkFloor", "GreenQuicCwndGrowthPhysicalThreshold",
    "GreenQuicCwndGrowthBlocksSleep", "GreenQuicRecoveryFloor",
    "GreenQuicRecoveryHardMaxPhysicalThreshold", "GreenQuicEnableRecoveryHardMax",
    "GreenQuicRecoveryBlocksSleep", "GreenQuicBlockedRxFloor",
    "GreenQuicBlockedSleepGuardLevel", "GreenQuicActiveTransferSleepMinLevel",
    "GreenQuicEnablePhysicalHardMax", "GreenQuicRxEmptyPollThreshold",
    "GreenQuicTxEmptyPollThreshold", "GreenQuicFreqUpPeriodUs",
    "GreenQuicFreqDownPeriodUs", "GreenQuicFreqMinIdleUs", "GreenQuicFreqPeriodUs",
    "GreenQuicSleepShortMinLevel", "GreenQuicSleepDataMinLevel",
    "GreenQuicSleepDeepMinLevel", "GreenQuicAckPathMaxSleepUs",
    "GreenQuicDataPathMaxSleepUs", "GreenQuicMaxSleepUs",
    "GreenQuicLogLevel", "GreenQuicStatsPeriodUs",
}
V21_POWER_KEYS = {
    "GreenQuicEnableCStateIdle", "GreenQuicCStateMinIdleUs",
    "GreenQuicCStateMinLevel", "GreenQuicCStateDeepMinLevel",
    "GreenQuicCStateWaitUs", "GreenQuicCStateDeepWaitUs",
    "GreenQuicCStateMaxWaitUs", "GreenQuicCStateTxOwnerMaxWaitUs",
    "GreenQuicCStateAllowDuringActiveTransfer", "GreenQuicIdleMode",
    "GreenQuicIdleFallback", "GreenQuicWorkWaitMinIdleUs",
    "GreenQuicWorkWaitMinLevel", "GreenQuicIdleWatchdogUs",
    "GreenQuicAllowWorkWaitDuringActiveTransfer", "GreenQuicEpollMaxEvents",
}
POWER_KEYS = V18_POWER_KEYS | V21_POWER_KEYS
LEGACY_KEYS = {"GreenQuicEwmaRiseShift", "GreenQuicEwmaFallShift"}
MODES = {"off", "basic", "plus", "0", "1", "2", "greenquic", "greenquic+"}
PROFILES = {"symmetric", "server_download", "client_download", "server_upload", "client_upload"}
QUIC_PROFILES = {"max_throughput", "low_latency", "low-latency", "scavenger", "real_time", "real-time"}
IDLE_MODES = {"off", "short", "pause", "monitor", "epoll", "auto"}
IDLE_FALLBACKS = {"short", "off", "fail"}
BOOL_TOPOLOGY = {"GreenQuicEnableMultiCore", "GreenQuicTxOwnerAlsoRx", "GreenQuicEnableRx", "GreenQuicEnableTx", "GreenQuicQuicAffinitize"}
BOOL_POWER = {
    "GreenQuicEnableFreq", "GreenQuicEnableSleep", "GreenQuicNoSleepIfTxRingNotEmpty",
    "GreenQuicTxRingProtectUp", "GreenQuicEnableAckRxHardMax", "GreenQuicAckBlocksSleep",
    "GreenQuicCwndGrowthBlocksSleep", "GreenQuicEnableRecoveryHardMax",
    "GreenQuicRecoveryBlocksSleep", "GreenQuicEnablePhysicalHardMax",
    "GreenQuicEnableCStateIdle", "GreenQuicCStateAllowDuringActiveTransfer",
    "GreenQuicAllowWorkWaitDuringActiveTransfer",
}
REQUIRED_POWER = {
    "GreenQuicEnableFreq", "GreenQuicEnableSleep", "GreenQuicPressureScale",
    "GreenQuicPressureMaxThreshold", "GreenQuicPressureUpThreshold",
    "GreenQuicPressureKeepThreshold", "GreenQuicRxQueueHigh",
    "GreenQuicRxQueueSamplePeriod", "GreenQuicTxRingHigh",
    "GreenQuicRxBurstRiseAlphaPermille", "GreenQuicRxBurstFallAlphaPermille",
    "GreenQuicRxQueueRiseAlphaPermille", "GreenQuicRxQueueFallAlphaPermille",
    "GreenQuicTxBurstRiseAlphaPermille", "GreenQuicTxBurstFallAlphaPermille",
    "GreenQuicTxRingRiseAlphaPermille", "GreenQuicTxRingFallAlphaPermille",
    "GreenQuicFullBurstMaxCount", "GreenQuicRxEmptyPollThreshold",
    "GreenQuicTxEmptyPollThreshold", "GreenQuicFreqUpPeriodUs",
    "GreenQuicFreqDownPeriodUs", "GreenQuicFreqMinIdleUs",
    "GreenQuicSleepShortMinLevel", "GreenQuicSleepDataMinLevel",
    "GreenQuicSleepDeepMinLevel", "GreenQuicAckPathMaxSleepUs",
    "GreenQuicDataPathMaxSleepUs", "GreenQuicMaxSleepUs",
} | V21_POWER_KEYS

def parse(path: Path):
    values: dict[str, str] = {}; duplicates: list[str] = []
    for no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"): continue
        if "=" not in line: raise ValueError(f"{path}:{no}: expected key=value")
        key, val = (x.strip() for x in line.split("=", 1))
        if not key: raise ValueError(f"{path}:{no}: empty key")
        if key in values: duplicates.append(key)
        values[key] = val
    return values, duplicates

def as_int(values, key, errors, required=True):
    if key not in values:
        if required: errors.append(f"missing required key: {key}")
        return None
    text = values[key]
    if not re.fullmatch(r"(?:0[xX][0-9a-fA-F]+|[0-9]+)", text):
        errors.append(f"{key} must be a non-negative integer, got {text!r}"); return None
    try: value = int(text, 0)
    except ValueError:
        errors.append(f"{key} must be an integer, got {text!r}"); return None
    if value > 0xFFFFFFFF:
        errors.append(f"{key} exceeds uint32: {value}"); return None
    return value

def parse_cpu_set(text, key, errors, allow_ranges):
    cpus=[]
    if not text.strip(): errors.append(f"{key} must not be empty"); return cpus
    for token in text.split(','):
        token=token.strip()
        if re.fullmatch(r"\d+", token): cpus.append(int(token))
        elif allow_ranges and re.fullmatch(r"\d+-\d+", token):
            lo,hi=map(int,token.split('-',1))
            if lo>hi: errors.append(f"{key} has descending range {token!r}")
            else: cpus.extend(range(lo,hi+1))
        else: errors.append(f"{key} has invalid CPU/lcore token {token!r}")
    if any(x>65535 for x in cpus): errors.append(f"{key} values must be in 0..65535")
    if len(cpus)!=len(set(cpus)): errors.append(f"{key} contains duplicate CPUs/lcores")
    return cpus

def parse_partition_map(text, errors):
    result={}
    if not text.strip(): errors.append("GreenQuicPartitionDpdkMap must not be empty"); return result
    for token in text.split(','):
        token=token.strip(); m=re.fullmatch(r"(\d+):(\d+)",token)
        if not m: errors.append(f"GreenQuicPartitionDpdkMap has invalid entry {token!r}"); continue
        p,l=map(int,m.groups())
        if p>65535 or l>65535: errors.append(f"GreenQuicPartitionDpdkMap entry {token!r} exceeds uint16")
        if p in result: errors.append(f"GreenQuicPartitionDpdkMap repeats partition {p}")
        result[p]=l
    return result

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def validate(dpdk_path: Path, power_path: Path, allow_device_placeholder: bool=False):
    errors=[]; warnings=[]
    dpdk,dup_d=parse(dpdk_path); power,dup_p=parse(power_path)
    if dup_d: errors.append("duplicate dpdk.ini keys: "+", ".join(sorted(set(dup_d))))
    if dup_p: errors.append("duplicate powermng.ini keys: "+", ".join(sorted(set(dup_p))))
    for key in dpdk:
        if key in POWER_KEYS or key in LEGACY_KEYS: errors.append(f"{key} belongs in powermng.ini, not dpdk.ini")
        elif key not in TOPOLOGY_KEYS: errors.append(f"unknown dpdk.ini key: {key}")
    for key in power:
        if key in LEGACY_KEYS: errors.append(f"legacy shared-EWMA key is forbidden: {key}")
        elif key not in POWER_KEYS: errors.append(f"unknown powermng.ini key: {key}")
    for key in REQUIRED_POWER:
        if key not in power: errors.append(f"missing required V22 key: {key}")

    device=dpdk.get("DeviceName","").strip()
    if not device: errors.append("DeviceName must not be empty")
    if device.startswith("<SET_") and not allow_device_placeholder: errors.append("DeviceName still contains a placeholder")
    local_ip=dpdk.get("LocalIp", "").strip()
    peer_mac=dpdk.get("PeerMac", "").strip()
    dpdk_args=dpdk.get("DpdkInitArgs", "").strip()
    if local_ip:
        try:
            import ipaddress
            ipaddress.IPv4Address(local_ip)
        except ValueError:
            errors.append(f"LocalIp must be a valid IPv4 address, got {local_ip!r}")
    if peer_mac and peer_mac.startswith("<SET_") and allow_device_placeholder:
        pass
    elif peer_mac and not re.fullmatch(r"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}", peer_mac):
        errors.append(f"PeerMac must be a colon-separated MAC address, got {peer_mac!r}")
    if dpdk_args and device and device not in dpdk_args:
        warnings.append("DpdkInitArgs does not contain DeviceName; verify the EAL allowlist")
    mode=dpdk.get("GreenQuicMode","").lower()
    if mode not in MODES: errors.append(f"GreenQuicMode is invalid: {dpdk.get('GreenQuicMode')!r}")
    profile=dpdk.get("GreenQuicProfile","").lower()
    if profile not in PROFILES: errors.append(f"GreenQuicProfile is invalid: {dpdk.get('GreenQuicProfile')!r}")
    qprofile=dpdk.get("GreenQuicQuicProfile","max_throughput").lower()
    if qprofile not in QUIC_PROFILES: errors.append(f"GreenQuicQuicProfile is invalid: {dpdk.get('GreenQuicQuicProfile')!r}")
    for key in BOOL_TOPOLOGY:
        if key in dpdk:
            val=as_int(dpdk,key,errors)
            if val not in (0,1,None): errors.append(f"{key} must be 0 or 1")

    lcore_text=dpdk.get("GreenQuicDpdkLcores") or dpdk.get("GreenQuicDpdkLcore","")
    lcores=parse_cpu_set(lcore_text,"GreenQuicDpdkLcores",errors,True)
    workers=parse_cpu_set(dpdk.get("GreenQuicQuicWorkerCpus",""),"GreenQuicQuicWorkerCpus",errors,False)
    tx_owner=as_int(dpdk,"GreenQuicTxOwnerLcore",errors)
    if tx_owner is not None and tx_owner not in lcores: errors.append("GreenQuicTxOwnerLcore must be one of GreenQuicDpdkLcores")
    pmap=parse_partition_map(dpdk.get("GreenQuicPartitionDpdkMap",""),errors)
    bad=sorted({l for l in pmap.values() if l not in lcores})
    if bad: errors.append(f"partition map targets lcores not enabled by GreenQuicDpdkLcores: {bad}")
    if set(lcores)&set(workers): errors.append("DPDK lcores and MsQuic worker CPUs overlap")
    multi=as_int(dpdk,"GreenQuicEnableMultiCore",errors)
    if multi==0 and len(lcores)!=1: errors.append("single-core mode requires exactly one DPDK lcore")
    if multi==1 and len(lcores)<2: errors.append("multi-core mode requires at least two DPDK lcores")

    for key in BOOL_POWER:
        val=as_int(power,key,errors)
        if val not in (0,1,None): errors.append(f"{key} must be 0 or 1")
    scale=as_int(power,"GreenQuicPressureScale",errors); keep=as_int(power,"GreenQuicPressureKeepThreshold",errors)
    up=as_int(power,"GreenQuicPressureUpThreshold",errors); maxv=as_int(power,"GreenQuicPressureMaxThreshold",errors)
    if None not in (scale,keep,up,maxv):
        if scale<=0: errors.append("GreenQuicPressureScale must be > 0")
        if not (0<=keep<=up<=maxv<=scale): errors.append("threshold order must be 0 <= keep <= up <= max <= scale")
    for key in [k for k in power if k.endswith("AlphaPermille")]:
        val=as_int(power,key,errors)
        if val is not None and not 0<=val<=1000: errors.append(f"{key} must be in 0..1000")
    for key,valstr in power.items():
        if scale is not None and ("Floor" in key or key.endswith("PhysicalThreshold") or key.endswith("HardMaxThreshold")):
            val=as_int(power,key,errors)
            if val is not None and not 0<=val<=scale: errors.append(f"{key} must be in 0..GreenQuicPressureScale")
    positive=("GreenQuicRxQueueHigh","GreenQuicRxQueueSamplePeriod","GreenQuicTxRingHigh",
              "GreenQuicFullBurstMaxCount","GreenQuicRxEmptyPollThreshold","GreenQuicTxEmptyPollThreshold",
              "GreenQuicFreqUpPeriodUs","GreenQuicFreqDownPeriodUs","GreenQuicFreqMinIdleUs","GreenQuicFreqPeriodUs")
    for key in positive:
        val=as_int(power,key,errors)
        if val is not None and val<=0: errors.append(f"{key} must be > 0")
    nonnegative=("GreenQuicBlockedSleepGuardLevel","GreenQuicActiveTransferSleepMinLevel",
                 "GreenQuicSleepShortMinLevel","GreenQuicSleepDataMinLevel","GreenQuicSleepDeepMinLevel",
                 "GreenQuicAckPathMaxSleepUs","GreenQuicDataPathMaxSleepUs","GreenQuicMaxSleepUs",
                 "GreenQuicLogLevel","GreenQuicStatsPeriodUs")
    vals={k:as_int(power,k,errors,required=k in REQUIRED_POWER) for k in nonnegative}
    short,data,deep=(vals.get("GreenQuicSleepShortMinLevel"),vals.get("GreenQuicSleepDataMinLevel"),vals.get("GreenQuicSleepDeepMinLevel"))
    if None not in (short,data,deep) and not short<=data<=deep: errors.append("sleep levels must satisfy short <= data <= deep")
    max_sleep=vals.get("GreenQuicMaxSleepUs")
    for key in ("GreenQuicAckPathMaxSleepUs","GreenQuicDataPathMaxSleepUs"):
        if max_sleep is not None and vals.get(key) is not None and vals[key]>max_sleep: errors.append(f"{key} must not exceed GreenQuicMaxSleepUs")
    if as_int(power,"GreenQuicEnableSleep",errors)==1 and max_sleep==0 and power.get("GreenQuicIdleMode","short").lower()=="short":
        errors.append("short sleep enabled but GreenQuicMaxSleepUs is zero")
    if vals.get("GreenQuicLogLevel") is not None and not 0<=vals["GreenQuicLogLevel"]<=2: errors.append("GreenQuicLogLevel must be in 0..2")

    idle_mode=power.get("GreenQuicIdleMode","").lower(); fallback=power.get("GreenQuicIdleFallback","").lower()
    if idle_mode not in IDLE_MODES: errors.append(f"GreenQuicIdleMode is invalid: {power.get('GreenQuicIdleMode')!r}")
    if fallback not in IDLE_FALLBACKS: errors.append(f"GreenQuicIdleFallback is invalid: {power.get('GreenQuicIdleFallback')!r}")
    enable_sleep=as_int(power,"GreenQuicEnableSleep",errors)
    if idle_mode in {"short","pause","monitor","epoll","auto"} and enable_sleep!=1:
        errors.append(f"GreenQuicIdleMode={idle_mode} requires GreenQuicEnableSleep=1")
    cmin=as_int(power,"GreenQuicCStateMinLevel",errors); cdeep=as_int(power,"GreenQuicCStateDeepMinLevel",errors)
    cwait=as_int(power,"GreenQuicCStateWaitUs",errors); cdwait=as_int(power,"GreenQuicCStateDeepWaitUs",errors)
    cmax=as_int(power,"GreenQuicCStateMaxWaitUs",errors); txcap=as_int(power,"GreenQuicCStateTxOwnerMaxWaitUs",errors)
    if cmin is not None and cmin<1: errors.append("GreenQuicCStateMinLevel must be >= 1")
    if None not in (cmin,cdeep) and cdeep<cmin: errors.append("GreenQuicCStateDeepMinLevel must be >= GreenQuicCStateMinLevel")
    if cmax is not None and cmax>1_000_000: errors.append("GreenQuicCStateMaxWaitUs must be <= 1000000")
    for key,val in (("GreenQuicCStateWaitUs",cwait),("GreenQuicCStateDeepWaitUs",cdwait),("GreenQuicCStateTxOwnerMaxWaitUs",txcap)):
        if None not in (val,cmax) and val>cmax: errors.append(f"{key} must not exceed GreenQuicCStateMaxWaitUs")
    wmin=as_int(power,"GreenQuicWorkWaitMinIdleUs",errors); wlevel=as_int(power,"GreenQuicWorkWaitMinLevel",errors)
    watchdog=as_int(power,"GreenQuicIdleWatchdogUs",errors); maxevents=as_int(power,"GreenQuicEpollMaxEvents",errors)
    if wmin is not None and not 1<=wmin<=60_000_000: errors.append("GreenQuicWorkWaitMinIdleUs must be in 1..60000000")
    if wlevel is not None and not 1<=wlevel<=1_000_000: errors.append("GreenQuicWorkWaitMinLevel must be in 1..1000000")
    if watchdog is not None and not 1<=watchdog<=1_000_000: errors.append("GreenQuicIdleWatchdogUs must be in 1..1000000")
    if maxevents is not None and not 1<=maxevents<=32: errors.append("GreenQuicEpollMaxEvents must be in 1..32")
    c_alias=as_int(power,"GreenQuicEnableCStateIdle",errors)
    if idle_mode=="pause" and c_alias!=1: warnings.append("pause mode will force the compatibility alias GreenQuicEnableCStateIdle on at runtime; set it to 1 for an unambiguous manifest")
    if idle_mode!="pause" and c_alias==1: warnings.append("GreenQuicEnableCStateIdle=1 is ignored when an explicit non-pause GreenQuicIdleMode is selected")
    if fallback=="fail": warnings.append("GreenQuicIdleFallback=fail is hardware-gated and intentionally stops the datapath only when the selected mechanism is unavailable")
    if as_int(power,"GreenQuicAllowWorkWaitDuringActiveTransfer",errors)==1: warnings.append("work-triggered waiting during active transfer is enabled; treat this as a latency diagnostic until validated")

    enable_rx=as_int(dpdk,"GreenQuicEnableRx",errors); enable_tx=as_int(dpdk,"GreenQuicEnableTx",errors)
    owner_rx=as_int(dpdk,"GreenQuicTxOwnerAlsoRx",errors)
    has_rx_only = bool(multi==1 and enable_rx==1 and len(lcores)>=2)
    if idle_mode=="monitor" and not has_rx_only:
        warnings.append("monitor mode has no RX-only lcore in this topology and will use the configured fallback")
    if idle_mode in {"monitor","auto"} and multi==1 and owner_rx==0:
        pass
    return errors,warnings

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--dpdk',type=Path,required=True); ap.add_argument('--power',type=Path,required=True)
    ap.add_argument('--json-out',type=Path); ap.add_argument('--allow-device-placeholder',action='store_true')
    args=ap.parse_args(); missing=[p for p in (args.dpdk,args.power) if not p.is_file()]
    if missing:
        for p in missing: print(f"ERROR: missing file: {p}",file=sys.stderr)
        return 2
    try: errors,warnings=validate(args.dpdk,args.power,args.allow_device_placeholder)
    except (OSError,ValueError) as exc: print(f"ERROR: {exc}",file=sys.stderr); return 2
    report={"dpdk_ini":str(args.dpdk),"powermng_ini":str(args.power),"dpdk_sha256":sha(args.dpdk),"powermng_ini_sha256":sha(args.power),"errors":errors,"warnings":warnings}
    if args.json_out:
        args.json_out.parent.mkdir(parents=True,exist_ok=True); args.json_out.write_text(json.dumps(report,indent=2)+"\n",encoding='utf-8')
    for w in warnings: print('WARNING:',w,file=sys.stderr)
    for e in errors: print('ERROR:',e,file=sys.stderr)
    if errors: return 2
    print(f"V22 configuration valid: {args.dpdk} + {args.power}"); return 0
if __name__=='__main__': raise SystemExit(main())
