# CPUIdle state mapping

## Server

- Host: `idex`
- CPU: `19`

| Linux index | Real name | Description | Exit latency | Target residency |
|---:|---|---|---:|---:|
| state0 | POLL | CPUIDLE CORE POLL IDLE | 0 us | 0 us |
| state1 | C1 | MWAIT 0x00 | 1 us | 1 us |
| state2 | C1E | MWAIT 0x01 | 4 us | 4 us |
| state3 | C6 | MWAIT 0x20 | 170 us | 600 us |

## Client

- Host: `tinyman`
- CPU: `19`

| Linux index | Real name | Description | Exit latency | Target residency |
|---:|---|---|---:|---:|
| state0 | POLL | CPUIDLE CORE POLL IDLE | 0 us | 0 us |
| state1 | C1 | MWAIT 0x00 | 1 us | 1 us |
| state2 | C1E | MWAIT 0x01 | 4 us | 4 us |
| state3 | C6 | MWAIT 0x20 | 170 us | 600 us |

