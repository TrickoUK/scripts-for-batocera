import importlib.util, os, select, signal, sys, types
from pathlib import Path

import pytest

REPO = Path("/var/mnt/work/batocera-build/batocera.linux")
SRC = Path(os.environ.get("HOTKEYGEN_SRC", REPO / "package/batocera/utils/hotkeygen/hotkeygen.py"))
sys.path.insert(0, str(REPO / "python-src/python-batocera-common"))

ec = types.SimpleNamespace(EV_KEY=1, EV_REL=2, EV_SYN=0, REL_X=0, REL_Y=1, BTN_LEFT=0x110, KEY_MAX=0x2ff,
                           KEY_ESC=1, KEY_LEFTALT=56, KEY_F4=62, KEY_EXIT=174,
                           ecodes={"KEY_ESC": 1, "KEY_LEFTALT": 56, "KEY_F4": 62, "KEY_EXIT": 174, "BTN_LEFT": 0x110})

class UInput:
    def __init__(self, *a, **k): self.log = []; self.fail_on = set()
    def write(self, t, c, v):
        if t == 1 and v == 0 and c in self.fail_on: raise OSError("write failed")
        self.log.append((t, c, v))
    def syn(self): pass
    def close(self): pass

evdev = types.ModuleType("evdev"); evdev.ecodes = ec; evdev.UInput = UInput
evdev.InputDevice = object; evdev.InputEvent = object
sys.modules["evdev"] = evdev; sys.modules["evdev.ecodes"] = ec
pyudev = types.ModuleType("pyudev")
class _Mon:
    @staticmethod
    def from_netlink(ctx): return _Mon()
    def filter_by(self, **k): pass
    def start(self): pass
    def fileno(self): return 99
pyudev.Context = lambda: object(); pyudev.Monitor = _Mon; pyudev.Device = object
sys.modules["pyudev"] = pyudev

spec = importlib.util.spec_from_file_location("hotkeygen", SRC)
hk = importlib.util.module_from_spec(spec); sys.modules["hotkeygen"] = hk; spec.loader.exec_module(hk)
hk.send_reset_signal = lambda target: None
HAS_V2 = hasattr(hk.Daemon, "_Daemon__release")

ALT, F4, ESC, EXIT_BTN, FD = 56, 62, 1, 174, 7
GAME = {"name": "xemu", "keys": {"exit": [ALT, F4]}}
DEFAULT = {"name": "", "keys": {"exit": ESC}}

class Ev:
    def __init__(self, code, value): self.type, self.code, self.value = 1, code, value

class FakeDev:
    def __init__(self, fd=FD, path="/dev/input/event9"):
        self.fd, self.path, self.name, self.pressed, self.queue = fd, path, "evmapy", set(), []
    def fileno(self): return self.fd
    def active_keys(self):
        if self.pressed is None: raise OSError(19, "No such device")
        return list(self.pressed)
    def read_one(self): return self.queue.pop(0) if self.queue else None
    def close(self): pass

def daemon(ctx=GAME, with_device=True):
    d = hk.Daemon(permanent=False); d.context = ctx
    if with_device:
        dev = FakeDev(); d.input_devices_by_fd[FD] = dev; d.mappings_by_fd[FD] = {EXIT_BTN: "exit"}
        d.input_devices[dev.path] = dev
    return d

def press(d, code=EXIT_BTN, fd=FD):   d._Daemon__handle_event(Ev(code, 1), "exit", True, fd)
def release(d, code=EXIT_BTN, fd=FD): d._Daemon__handle_event(Ev(code, 0), "exit", False, fd)
def downs(d): return [c for (_, c, v) in d.target.log if v == 1]
def ups(d):   return [c for (_, c, v) in d.target.log if v == 0]

# ---------- behaviour shared with the first version of the fix ----------
def test_normal_press_release():
    d = daemon(); press(d); release(d)
    assert downs(d) == [ALT, F4] and ups(d) == [F4, ALT] and d.held_keys == {}

def test_late_release_after_context_change_releases_the_pressed_keys():
    d = daemon(); press(d); d.context_generation += 1; d.context = DEFAULT; release(d)
    assert set(ups(d)) == {ALT, F4} and ESC not in ups(d)

def test_command_context_unchanged():
    ran = []; hk.os.system = lambda c: ran.append(c)
    d = daemon({"name": "wine", "keys": {"exit": "batocera-wine windows stop"}})
    press(d); assert d.held_keys == {} and downs(d) == []
    release(d); assert ran == ["batocera-wine windows stop"]

def test_single_key_context():
    d = daemon(DEFAULT); press(d); release(d)
    assert downs(d) == [ESC] and ups(d) == [ESC] and d.held_keys == {}

needs_v2 = pytest.mark.skipif(not HAS_V2, reason="needs the hardened daemon")

# ---------- hardening ----------
@needs_v2
def test_a_failing_key_up_does_not_leave_the_other_keys_down():
    d = daemon(); press(d); d.target.fail_on = {F4}
    d._Daemon__release((FD, EXIT_BTN))                  # must not raise
    assert ALT in ups(d) and d.held_keys == {}

@needs_v2
def test_release_of_device_with_two_buttons_held():
    d = daemon(); press(d); press(d, code=175)
    d._Daemon__release_device(FD)
    assert d.held_keys == {} and ups(d).count(ALT) == 2 and ups(d).count(F4) == 2

@needs_v2
def test_release_device_leaves_other_devices_alone():
    d = daemon(); press(d, fd=7); press(d, code=EXIT_BTN, fd=8)
    d._Daemon__release_device(7); assert list(d.held_keys) == [(8, EXIT_BTN)]

@needs_v2
def test_lost_release_is_recovered_from_the_kernel_state():
    d = daemon(); press(d)
    d.input_devices_by_fd[FD].pressed = {EXIT_BTN}
    d._Daemon__release_matching(lambda s, _: not d._Daemon__is_pressed(s)); assert d.held_keys
    d.input_devices_by_fd[FD].pressed = set()                       # the release event never arrived
    d._Daemon__release_matching(lambda s, _: not d._Daemon__is_pressed(s))
    assert d.held_keys == {} and set(ups(d)) == {ALT, F4}

@pytest.mark.parametrize("state", ["gone", "enodev"])
@needs_v2
def test_vanished_device_counts_as_released(state):
    d = daemon(); press(d)
    if state == "gone": del d.input_devices_by_fd[FD]
    else: d.input_devices_by_fd[FD].pressed = None
    assert d._Daemon__is_pressed((FD, EXIT_BTN)) is False

@needs_v2
def test_sighup_wakes_the_loop_and_bumps_the_generation():
    d = daemon(); hk.get_context = lambda: DEFAULT
    g = d.context_generation; d._Daemon__handle_sighup(signal.SIGHUP, None)
    assert d.context_generation == g + 1 and d.context is DEFAULT and d.require_reconfig
    assert os.read(d.wake_r, 16) == b"\0"

@needs_v2
def test_sighup_with_a_full_wake_pipe_does_not_raise():
    d = daemon(); hk.get_context = lambda: DEFAULT
    try:
        while True: os.write(d.wake_w, b"\0" * 4096)
    except BlockingIOError: pass
    d._Daemon__handle_sighup(signal.SIGHUP, None)

# ---------- the real run() loop, driven by a scripted poll ----------
class Stop(Exception): pass

class FakePoll:
    def __init__(self, script, hooks): self.script, self.hooks, self.timeouts, self.registered = list(script), hooks, [], []
    def register(self, fd, mask=None): self.registered.append(fd)
    def unregister(self, fd): pass
    def poll(self, timeout):
        self.timeouts.append(timeout)
        if not self.script: raise Stop
        step = self.script.pop(0)
        if callable(step): step = step()
        return step

def run_loop(d, script, monkeypatch):
    class Ctx:
        def list_devices(self, **k): return []
    d.udev_context = Ctx(); d.poll = FakePoll(script, None)
    monkeypatch.setattr(hk, "get_context", lambda: d.context)
    monkeypatch.setattr(hk, "get_mapping", lambda dev: {EXIT_BTN: "exit"})
    old = signal.signal(signal.SIGHUP, signal.SIG_DFL)
    try:
        with pytest.raises(Stop): d.run()
    finally: signal.signal(signal.SIGHUP, old)
    return d.poll.timeouts

@needs_v2
def test_run_loop_releases_on_context_change_before_the_button_is_released(monkeypatch):
    d = daemon(); dev = d.input_devices_by_fd[FD]; dev.pressed = {EXIT_BTN}
    events = []
    def press_event():
        dev.queue.append(Ev(EXIT_BTN, 1)); return [(FD, select.POLLIN)]
    def game_exits():                       # launcher: hotkeygen --default-context while the button is still down
        monkeypatch.setattr(hk, "get_context", lambda: DEFAULT)
        d._Daemon__handle_sighup(signal.SIGHUP, None); events.append(list(d.target.log))
        return [(d.wake_r, select.POLLIN)]
    def physical_release():
        dev.pressed = set(); dev.queue.append(Ev(EXIT_BTN, 0)); return [(FD, select.POLLIN)]
    timeouts = run_loop(d, [press_event, game_exits, physical_release, [], []], monkeypatch)
    assert downs(d) == [ALT, F4]
    assert ups(d)[:2] == [F4, ALT], "keys must be up as soon as the context changed, not when the button is released"
    assert d.held_keys == {}
    assert timeouts[0] == 1000 and timeouts[1] == hk.HELD_KEYS_POLL_MS, timeouts   # fast poll only while holding
    assert timeouts[-1] == 1000

@needs_v2
def test_run_loop_recovers_a_release_that_never_arrives(monkeypatch):
    d = daemon(); dev = d.input_devices_by_fd[FD]; dev.pressed = {EXIT_BTN}
    def press_event(): dev.queue.append(Ev(EXIT_BTN, 1)); return [(FD, select.POLLIN)]
    def button_up_silently(): dev.pressed = set(); return []           # no release event is ever delivered
    run_loop(d, [press_event, [], button_up_silently, []], monkeypatch)
    assert d.held_keys == {} and set(ups(d)) == {ALT, F4}

@needs_v2
def test_run_loop_releases_when_the_source_device_errors_out(monkeypatch):
    d = daemon(); dev = d.input_devices_by_fd[FD]; dev.pressed = {EXIT_BTN}
    def press_event(): dev.queue.append(Ev(EXIT_BTN, 1)); return [(FD, select.POLLIN)]
    def device_dies():
        dev.read_one = lambda: (_ for _ in ()).throw(OSError(19, "No such device")); return [(FD, select.POLLIN)]
    run_loop(d, [press_event, device_dies, []], monkeypatch)
    assert d.held_keys == {} and set(ups(d)) == {ALT, F4} and FD not in d.input_devices_by_fd
