"""Transport-free six-zone occupancy-to-appliance simulation and static comparison."""
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw

from .zone_definition import ZONE_COLORS, ZONE_ORDER, assign_point, load_config, sha256
from .zone_review import _load_ground_truth

PAIRS = (("Z1", "Z2", "B1"), ("Z3", "Z4", "B2"), ("Z5", "Z6", "B3"))


@dataclass
class Settings:
    activation_seconds: float = 2.0
    vacancy_seconds: float = 30.0
    stale_seconds: float = 5.0


class VirtualControl:
    def __init__(self, settings: Settings):
        self.cfg = settings
        self.now = 0.0
        self.last_observation = None
        self.input_state = "UNKNOWN"
        self.raw = dict.fromkeys(ZONE_ORDER)
        self.candidate = dict.fromkeys(ZONE_ORDER)
        self.candidate_at = dict.fromkeys(ZONE_ORDER)
        self.demand = dict.fromkeys(ZONE_ORDER)
        self.outputs = {f"F{i}": False for i in range(1, 7)} | {f"L{i}": False for i in range(1, 7)} | {f"B{i}": False for i in range(1, 4)}
        self.overrides = {}
        self.log = []

    def record(self, reason, **data):
        self.log.append({"time_s": round(self.now, 3), "reason": reason, **data})

    def observe(self, occupancy, reason="valid_observation"):
        if occupancy is None:
            self.input_state = "UNKNOWN"
            self.candidate = dict.fromkeys(ZONE_ORDER)
            self.candidate_at = dict.fromkeys(ZONE_ORDER)
            self.record(reason, state="UNKNOWN", action="cancel_confirmation_hold_outputs")
            return
        if set(occupancy) != set(ZONE_ORDER) or any(type(v) is not bool for v in occupancy.values()):
            raise ValueError("Provide a bool occupancy for all six zones; {} is valid empty")
        self.input_state = "FRESH"
        self.last_observation = self.now
        self.raw = dict(occupancy)
        for z, occupied in occupancy.items():
            state = "OCCUPIED" if occupied else "VACANT"
            if self.candidate[z] != state:
                self.candidate[z], self.candidate_at[z] = state, self.now
            if self.demand[z] is None:
                if state == "VACANT" or self.now - self.candidate_at[z] >= self.cfg.activation_seconds:
                    self.demand[z] = occupied
                    self.record("demand_confirmed", zone=z, demand=occupied)
            elif occupied:
                self.demand[z] = True
            elif self.demand[z] and self.now - self.candidate_at[z] >= self.cfg.vacancy_seconds:
                self.demand[z] = False
                self.record("vacancy_delay_elapsed", zone=z, demand=False)
        self.record(reason, state="FRESH", raw_occupied=sorted(z for z,v in occupancy.items() if v))
        self._decide()

    def tick(self, now):
        if now < self.now:
            raise ValueError("virtual clock must not move backwards")
        self.now = float(now)
        if self.last_observation is None or self.now - self.last_observation >= self.cfg.stale_seconds:
            if self.input_state != "UNKNOWN":
                self.input_state = "UNKNOWN"
                self.candidate = dict.fromkeys(ZONE_ORDER)
                self.candidate_at = dict.fromkeys(ZONE_ORDER)
                self.record("stale_input", state="UNKNOWN", action="cancel_confirmation_hold_outputs")
        else:
            for z in ZONE_ORDER:
                if self.demand[z] is None and self.candidate[z] == "OCCUPIED" and self.now - self.candidate_at[z] >= self.cfg.activation_seconds:
                    self.demand[z] = True
                    self.record("demand_confirmed", zone=z, demand=True)
                elif self.demand[z] and self.candidate[z] == "VACANT" and self.now - self.candidate_at[z] >= self.cfg.vacancy_seconds:
                    self.demand[z] = False
                    self.record("vacancy_delay_elapsed", zone=z, demand=False)
            self._decide()

    def override(self, appliance, state):
        if appliance not in self.outputs or state not in ("ON", "OFF", "AUTO"):
            raise ValueError("invalid appliance override")
        if state == "AUTO":
            self.overrides.pop(appliance, None)
        else:
            self.overrides[appliance] = state
        self.record("manual_override", appliance=appliance, state=state)
        self._decide()

    def _decide(self):
        if self.input_state != "FRESH":
            return
        desired = {f"F{i}": self.demand[f"Z{i}"] for i in range(1,7)} | {f"L{i}": self.demand[f"Z{i}"] for i in range(1,7)}
        for a,b,shared in PAIRS:
            desired[shared] = bool(self.demand[a] or self.demand[b])
        for aid, manual in self.overrides.items():
            desired[aid] = manual == "ON"
        for aid, value in desired.items():
            if value is None:
                continue
            if self.outputs[aid] != value:
                self.outputs[aid] = value
                source = "manual" if aid in self.overrides else "automatic_stabilized_demand"
                self.record("output_transition", appliance=aid, state="ON" if value else "OFF", source=source)


def six(states):
    return {z: z in states for z in ZONE_ORDER}


def run_scenarios(settings):
    c = VirtualControl(settings)
    expected = []
    last_known = None
    def event(t, name, obs="skip", over=None, expectation="scripted input accepted"):
        nonlocal last_known
        # Keep a scripted source fresh while virtual time advances; these are
        # explicit synthetic observations, not repeated still-image identities.
        while c.now + 4.0 < t:
            beat = c.now + 4.0
            c.tick(beat)
            if last_known is not None and c.input_state != "UNKNOWN":
                c.observe(last_known, "synthetic_freshness_observation")
        c.tick(t)
        if obs != "skip":
            c.observe(obs, name)
            if obs is not None: last_known = obs
        if over: c.override(*over)
        expected.append({"time_s":t,"scenario":name,"expected":expectation,"observed_input":c.input_state,"observed_outputs":dict(c.outputs),"observed_demands":dict(c.demand)})
    event(0,"startup_unknown",None,expectation="UNKNOWN; hold automatic outputs")
    event(1,"valid_empty",six([]),expectation="VACANT confirmed; outputs OFF")
    event(3,"person_enters",six(["Z1"]),expectation="activation pending; outputs remain OFF")
    event(5,"entry_confirmed",six(["Z1"]),expectation="Z1 demand ON; F1,L1,B1 ON")
    event(6,"brief_disappearance",six([]),expectation="vacancy pending; outputs held ON")
    event(7,"person_returns",six(["Z1"]),expectation="vacancy timer resets; outputs remain ON")
    event(8,"person_leaves",six([]),expectation="vacancy delay starts; outputs held ON")
    event(38,"vacancy_confirmed",six([]),expectation="30s confirmed vacancy; Z1 outputs OFF")
    event(40,"paired_zone_a_occupied",six(["Z1"]))
    event(42,"paired_zone_a_confirmed",six(["Z1"]))
    event(43,"paired_zone_b_occupied",six(["Z1","Z2"]))
    event(45,"both_pair_zones_confirmed",six(["Z1","Z2"]))
    event(46,"one_paired_zone_empties",six(["Z2"]),expectation="B1 stays ON while Z2 demand remains")
    event(76,"one_pair_zone_still_lit",six(["Z2"]),expectation="B1 remains ON; Z1 fan/light may switch OFF")
    event(78,"last_pair_zone_empties",six([]))
    event(108,"pair_vacant",six([]))
    event(110,"movement_old_band",six(["Z1"]))
    event(112,"old_band_confirmed",six(["Z1"]))
    event(113,"movement_new_depth_band",six(["Z3"]))
    event(115,"new_band_confirmed",six(["Z3"]))
    c.tick(120)  # five seconds without input: stale UNKNOWN
    expected.append({"time_s":120,"scenario":"stale_input_threshold","expected":"UNKNOWN; automatic outputs held; vacancy timer suspended","observed_input":c.input_state,"observed_outputs":dict(c.outputs),"observed_demands":dict(c.demand)})
    event(121,"inference_failure",None)
    event(125,"recovery_fresh_observation",six(["Z3"]))
    event(127,"recovery_confirmed",six(["Z3"]))
    event(128,"manual_on",six(["Z3"]),("F3","ON"))
    event(129,"manual_off",six(["Z3"]),("L3","OFF"))
    event(130,"return_auto",six(["Z3"]),("F3","AUTO"))
    event(131,"manual_light_auto",six(["Z3"]),("L3","AUTO"))
    return c, expected


def static_compare(config, review_path, labels_path, images, out):
    review=json.loads(review_path.read_text(encoding="utf-8")); info,gt=_load_ground_truth(labels_path)
    rows=[]; frames={}
    for e in review["entries"]:
        if e.get("review_status")!="reviewed" or e["expected_zone"] not in ZONE_ORDER: continue
        x1,y1,x2,y2=e["box"]
        rec={"file":e["file"],"annotation_id":e["annotation_id"],"expected":e["expected_zone"]}
        for f in (.5,.75):
            res=assign_point(config,((x1+x2)/2,y1+f*(y2-y1)))
            rec[f"f_{f:.2f}"]=res["zone"]
        rows.append(rec)
        frame=frames.setdefault(e["file"],{"expected":set(),"f_0.50":set(),"f_0.75":set()})
        frame["expected"].add(e["expected_zone"])
        for f in (.5,.75):
            if rec[f"f_{f:.2f}"] in ZONE_ORDER: frame[f"f_{f:.2f}"].add(rec[f"f_{f:.2f}"])
    per_frame=[]
    for filename,frame in sorted(frames.items()):
        per_frame.append({"file":filename,"expected_occupied_zones":sorted(frame["expected"]),**{f"{key}_occupied_zones":sorted(val) for key,val in frame.items() if key!="expected"},**{f"{key}_missed":sorted(frame["expected"]-frame[key]) for key in ("f_0.50","f_0.75")},**{f"{key}_false":sorted(frame[key]-frame["expected"]) for key in ("f_0.50","f_0.75")},**{f"{key}_exact":frame[key]==frame["expected"] for key in ("f_0.50","f_0.75")}})
    _write(out/"static_comparison.json",{"diagnostic_only":True,"continuous_timing_inferred":False,"track_ids_invented":False,"people":len(rows),"frames":per_frame,"rows":rows})


def _write(path,data):
    path.parent.mkdir(parents=True,exist_ok=True); path.write_text(json.dumps(data,indent=2)+"\n",encoding="utf-8")


def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument("--output",type=Path,default=Path("outputs/zone_definition/manual_review/six_zone_control_simulation")); p.add_argument("--activation",type=float,default=2.0);p.add_argument("--vacancy",type=float,default=30.0);p.add_argument("--stale",type=float,default=5.0)
    a=p.parse_args(); out=a.output; out.mkdir(parents=True,exist_ok=True); settings=Settings(a.activation,a.vacancy,a.stale)
    control,expected=run_scenarios(settings)
    cfg=load_config(Path("config/zones/diagnostic_six_zone_aisle_proposal.json"))
    static_compare(cfg,Path("outputs/zone_definition/manual_review/expected_zone_review.json"),Path("outputs/dataset_diagnosis/review_set/ground_truth/labels.coco.json"),Path("outputs/dataset_diagnosis/review_set/images"),out)
    result={"diagnostic_only":True,"transport":"none","settings_simulation_only":settings.__dict__,"scenarios":expected,"transitions":control.log,"final_outputs":control.outputs,"source_hashes":{"config":sha256(Path("config/zones/diagnostic_six_zone_aisle_proposal.json")),"review":sha256(Path("outputs/zone_definition/manual_review/expected_zone_review.json")),"labels":sha256(Path("outputs/dataset_diagnosis/review_set/ground_truth/labels.coco.json"))}}
    _write(out/"simulation.json",result)
    transitions=[x for x in control.log if x["reason"]=="output_transition"]
    lines=["# Six-zone appliance control simulation (diagnostic only)","","Virtual clock; no inference, broker, MQTT or hardware. Settings are simulation defaults, not approved device values.","","## Compact appliance timeline","","| Time (s) | Appliance | State | Reason |","|---:|---|---|---|"]
    lines.extend(f"| {x['time_s']:.1f} | {x['appliance']} | {x['state']} | {x['source']} |" for x in transitions)
    lines += ["","Scenario expectations and observed snapshots, plus the full reasoned event log, are in `simulation.json`. Still-frame manual occupancy versus centre/f=.75 assignments is in `static_comparison.json`; it is not replayed as continuous time and has no inferred track identities.","","## Mapping limits","","Six-zone geometry is provisional desktop image-space geometry, with the central aisle owned by Z1/Z3/Z5. Anchors f=.50 and f=.75 are comparison/diagnostic choices only. Annotations 118 and 171 remain unresolved mapping cases. No physical calibration or appliance accuracy is established.",""]
    (out/"simulation.md").write_text("\n".join(lines),encoding="utf-8")
    print(json.dumps({"output":str(out),"events":len(control.log),"settings":settings.__dict__,"transport":"none"},indent=2))

if __name__=="__main__": main()
