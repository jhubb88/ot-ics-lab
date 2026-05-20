(* =============================================================================
   OT/ICS Security Lab — Phase 1
   tank_fill.st — OpenPLC v3 (MATIEC / IEC 61131-3 Structured Text)

   WHY THIS PROGRAM SIMULATES ITS OWN PROCESS (recruiter-facing rationale —
   DO NOT delete this comment):

   This lab has NO physical I/O and is deliberately NOT run --privileged
   (see docker-compose.yml + docs/network-security.md). With no real sensor
   or actuator, the tank level cannot come from hardware. So this single
   program does two jobs on every scan:

     1. PROCESS MODEL  — integrates a simulated tank level from the current
                         pump/valve state (the "plant").
     2. CONTROL LOGIC  — hysteresis fill control + high-high alarm (the "PLC").

   This is the standard approach for a hardware-less OpenPLC teaching/lab
   rig: it produces real, capturable Modbus/TCP traffic (Deliverable 7,
   Wireshark) and a live HMI animation (FUXA) without any hardware.

   MODBUS MAP (OpenPLC v3 fixed mapping — consumed by FUXA, Deliverable 4):
     %QW0  Level_PV    -> Holding Register 0   (tank level, 0..100 %)
     %QW1  SP_Low      -> Holding Register 1   (low setpoint, display only)
     %QW2  SP_High     -> Holding Register 2   (high setpoint, display only)
     %QX0.0 Pump_Run   -> Coil 0               (pump command)
     %QX0.1 Valve_Open -> Coil 1               (inlet valve command)
     %QX0.2 High_Alarm -> Coil 2               (high-high level alarm)

   Structured Text is niche and the MATIEC compiler is strict; a fix pass on
   first upload is expected, not a blocker (tracked in docs/MASTER.md).
   ============================================================================= *)

PROGRAM prog0

  (* MATIEC fix pass (first-compile, documented in docs/MASTER.md): OpenPLC's
     MATIEC parser rejects mixing AT-located and non-located variables in one
     VAR..END_VAR block. The located (Modbus-mapped) outputs therefore live in
     their own VAR block, separate from the non-located internal state. This is
     the standard OpenPLC v3 Structured Text pattern. *)
  VAR
    (* --- Outputs exposed over Modbus to the FUXA HMI ----------------------- *)
    Level_PV    AT %QW0   : INT  := 50;   (* tank level, 0..100 %            *)
    SP_Low_Out  AT %QW1   : INT  := 20;   (* mirror of SP_Low for the HMI    *)
    SP_High_Out AT %QW2   : INT  := 80;   (* mirror of SP_High for the HMI   *)
    Pump_Run    AT %QX0.0 : BOOL := FALSE;
    Valve_Open  AT %QX0.1 : BOOL := FALSE;
    High_Alarm  AT %QX0.2 : BOOL := FALSE;
  END_VAR

  VAR
    (* --- Internal control state (retained between scans) ------------------- *)
    Fill_Active : BOOL := FALSE;   (* hysteresis latch: TRUE = filling        *)
    Level       : INT  := 50;      (* working copy of the simulated level     *)

    (* --- Tuning constants (internal on purpose: fewer first-run failure
           modes for a beginner — same philosophy as "no .env in Phase 1") --- *)
    SP_Low      : INT := 20;   (* start filling at/below this level (%)        *)
    SP_High     : INT := 80;   (* stop  filling at/above this level (%)        *)
    SP_AlarmHH  : INT := 90;   (* high-high alarm threshold (%)               *)
    FILL_RATE   : INT := 2;    (* level rise per 100 ms scan while filling    *)
    DRAIN_RATE  : INT := 1;    (* continuous consumption per scan (always)    *)
  END_VAR

  (* ---------------------------------------------------------------------------
     1. CONTROL LOGIC — hysteresis fill control
     Latch ON at/below SP_Low, latch OFF at/above SP_High. The dead band
     between the setpoints stops the pump short-cycling (real-plant practice).
     --------------------------------------------------------------------------- *)
  IF Level <= SP_Low THEN
    Fill_Active := TRUE;
  ELSIF Level >= SP_High THEN
    Fill_Active := FALSE;
  END_IF;

  Pump_Run   := Fill_Active;
  Valve_Open := Fill_Active;
  High_Alarm := Level >= SP_AlarmHH;

  (* ---------------------------------------------------------------------------
     2. PROCESS MODEL — integrate the simulated tank level
     Inflow only while pump + valve are active; a constant consumption draws
     the tank down every scan, so the level continuously cycles for the demo.
     --------------------------------------------------------------------------- *)
  IF Fill_Active THEN
    Level := Level + FILL_RATE;
  END_IF;

  Level := Level - DRAIN_RATE;

  (* Clamp to a physical 0..100 % range *)
  IF Level > 100 THEN
    Level := 100;
  END_IF;
  IF Level < 0 THEN
    Level := 0;
  END_IF;

  (* ---------------------------------------------------------------------------
     3. PUBLISH to the Modbus-mapped registers the HMI reads
     --------------------------------------------------------------------------- *)
  Level_PV    := Level;
  SP_Low_Out  := SP_Low;
  SP_High_Out := SP_High;

END_PROGRAM


CONFIGURATION Config0

  RESOURCE Res0 ON PLC
    TASK Main(INTERVAL := T#100ms, PRIORITY := 0);
    PROGRAM Inst0 WITH Main : prog0;
  END_RESOURCE

END_CONFIGURATION
