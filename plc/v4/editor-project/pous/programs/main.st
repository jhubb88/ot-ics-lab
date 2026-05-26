PROGRAM main
VAR
	Level_PV : int AT %QW0 := 50; (* tank level, 0..100% *)
	SP_Low_Out : int AT %QW1 := 20; (* mirror of SP_Low for the HMI *)
	SP_High_Out : int AT %QW2 := 80; (* mirror of SP_High for the HMI *)
	Pump_Run : bool AT %QX0.0 := FALSE; (* pump command *)
	Valve_Open : bool AT %QX0.1 := FALSE; (* inlet valve command *)
	High_Alarm : bool AT %QX0.2 := FALSE; (* high-high level alarm *)
	Fill_Active : bool := FALSE; (* hysteresis latch: TRUE = filling *)
	Level : int := 50; (* working copy of the simulated level *)
	SP_Low : int := 20; (* start filling at/below this level (%) *)
	SP_High : int := 80; (* stop filling at/above this level (%) *)
	SP_AlarmHH : int := 90; (* high-high alarm threshold (%) *)
	FILL_RATE : int := 2; (* level rise per scan while filling *)
	DRAIN_RATE : int := 1; (* continuous consumption per scan *)
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