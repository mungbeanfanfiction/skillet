from supervisorlib import capacity

ENV = capacity.ENV_VAR


def test_host_cap_never_exceeds_the_historical_ceiling():
    assert capacity.host_cap(64, 256) == capacity.MAX_CAP


def test_host_cap_takes_the_scarcer_of_cpu_and_ram():
    # 16 CPUs would allow 4 slots, but 6 GiB only affords 1.
    assert capacity.host_cap(16, 6) == 1
    # 24 GiB would allow 4 slots, but 8 CPUs only afford 2.
    assert capacity.host_cap(8, 24) == 2


def test_host_cap_floors_at_one_on_a_tiny_host():
    assert capacity.host_cap(1, 1) == capacity.MIN_CAP


def test_host_cap_ignores_unknown_resources_rather_than_throttling():
    # A host we can't introspect must fall back to the ceiling, not to 1.
    assert capacity.host_cap(None, None) == capacity.MAX_CAP
    # One known, one unknown: budget on the one we have.
    assert capacity.host_cap(8, None) == 2
    assert capacity.host_cap(None, 6) == 1


def test_default_cap_is_within_bounds_on_this_host():
    assert capacity.MIN_CAP <= capacity.default_cap() <= capacity.MAX_CAP


def test_resolve_cap_honours_an_override_beyond_the_ceiling():
    assert capacity.resolve_cap({ENV: "8"}) == 8


def test_resolve_cap_ignores_a_malformed_override():
    # "²" is str.isdigit() but not int()-parseable; it must fall back, not raise —
    # an escaped ValueError would abort the survey cycle via survey.sh's ERR trap.
    for bad in ("", "  ", "0", "-2", "three", "2.5", "²"):
        assert capacity.resolve_cap({ENV: bad}) == capacity.default_cap()


def test_resolve_cap_falls_back_to_the_host_default_when_unset():
    assert capacity.resolve_cap({}) == capacity.default_cap()
