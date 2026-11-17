from src.six_zone_control_simulation import Settings, VirtualControl, run_scenarios, six


def test_startup_unknown_and_stale_hold_outputs_without_vacancy_credit():
    c = VirtualControl(Settings())
    c.observe(six(["Z1"]))
    c.tick(2)
    assert c.outputs["F1"] is True
    before = dict(c.outputs)
    c.tick(7)  # age == stale threshold
    assert c.input_state == "UNKNOWN"
    assert c.outputs == before
    assert c.demand["Z1"] is True
    c.observe(six([]))
    for t in (11, 15, 19, 23, 27, 31, 35):
        c.tick(t)
        c.observe(six([]), "fresh_heartbeat")
    c.tick(36.9)
    assert c.outputs["F1"] is True
    c.tick(37)
    assert c.outputs["F1"] is False


def test_paired_shared_light_stays_on_while_other_zone_is_stabilized_occupied():
    c = VirtualControl(Settings())
    c.observe(six(["Z1", "Z2"]))
    c.tick(2)
    assert c.outputs["B1"] is True
    c.observe(six(["Z2"]))
    for t in (6, 10, 14, 18, 22, 26, 30):
        c.tick(t)
        c.observe(six(["Z2"]), "fresh_heartbeat")
    c.tick(31.9)
    assert c.outputs["B1"] is True
    c.tick(32)
    assert c.outputs["B1"] is True
    assert c.outputs["F2"] is True


def test_manual_precedence_and_auto_return():
    c = VirtualControl(Settings())
    c.observe(six(["Z3"]))
    c.tick(2)
    c.override("F3", "OFF")
    assert c.outputs["F3"] is False
    c.override("F3", "AUTO")
    assert c.outputs["F3"] is True
    c.override("L3", "OFF")
    assert c.outputs["L3"] is False
    c.observe(six([]))
    assert c.outputs["L3"] is False


def test_scripted_scenarios_emit_failure_recovery_and_override_reasons():
    c, _ = run_scenarios(Settings())
    reasons = {row["reason"] for row in c.log}
    assert {"stale_input", "inference_failure", "recovery_fresh_observation", "manual_override", "vacancy_delay_elapsed"} <= reasons
    assert c.input_state == "FRESH"
