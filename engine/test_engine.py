"""Exercises PinSession against a fake device (no iPhone needed).

Run: python engine/test_engine.py
"""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import engine  # noqa: E402

engine.KEEPALIVE_SECONDS = 0.05
engine.MAX_BACKOFF_SECONDS = 0.05
engine.emit = lambda msg: events.append(msg)

events: list[dict] = []


class FakeDevice:
    def __init__(self) -> None:
        self.calls: list[tuple] = []
        self.mounted = True
        self.reachable = True
        self.drop_next_set = False


device = FakeDevice()


class FakeRSD:
    async def close(self) -> None:
        pass


async def fake_connect(udid):
    if not device.reachable:
        raise ConnectionError(engine.UNREACHABLE)
    return FakeRSD()


class FakeDvt:
    def __init__(self, rsd) -> None:
        pass

    async def __aenter__(self):
        if not device.mounted:
            raise RuntimeError("InvalidService")
        return self

    async def __aexit__(self, *exc):
        return False


class FakeSim:
    def __init__(self, dvt) -> None:
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def set(self, lat, lng):
        if device.drop_next_set:
            device.drop_next_set = False
            raise ConnectionResetError("channel died")
        device.calls.append(("set", lat, lng))

    async def clear(self):
        device.calls.append(("clear",))


async def fake_mount(rsd):
    device.calls.append(("mount",))
    device.mounted = True


engine.connect_rsd = fake_connect
engine.DvtProvider = FakeDvt
engine.LocationSimulation = FakeSim
engine.auto_mount = fake_mount


def states() -> list[str]:
    return [e["state"] for e in events if e.get("type") == "session"]


async def wait_for(pred, timeout=2.0):
    end = asyncio.get_running_loop().time() + timeout
    while not pred():
        assert asyncio.get_running_loop().time() < end, f"timed out; events={events} calls={device.calls}"
        await asyncio.sleep(0.01)


async def main() -> None:
    eng = engine.Engine()

    # Pin, then the keepalive keeps re-asserting the same point.
    await eng.handle({"cmd": "set", "udid": "A", "lat": 1, "lng": 2})
    await wait_for(lambda: "pinned" in states())
    await wait_for(lambda: device.calls.count(("set", 1.0, 2.0)) >= 3)

    # Moving reuses the open channel (no clear in between).
    await eng.handle({"cmd": "set", "udid": "A", "lat": 3, "lng": 4})
    await wait_for(lambda: ("set", 3.0, 4.0) in device.calls)
    assert ("clear",) not in device.calls

    # Channel dies -> reconnecting -> pinned again at the latest point.
    events.clear()
    device.drop_next_set = True
    await wait_for(lambda: "reconnecting" in states() and states()[-1] == "pinned")

    # iPhone rebooted: DDI gone -> mounted automatically, then pinned.
    events.clear()
    device.mounted = False
    device.drop_next_set = True
    await wait_for(lambda: ("mount",) in device.calls and states() and states()[-1] == "pinned")

    # Unreachable device keeps retrying with a readable error.
    events.clear()
    device.reachable = False
    device.drop_next_set = True
    await wait_for(lambda: any(e.get("error") == engine.UNREACHABLE for e in events))
    device.reachable = True
    await wait_for(lambda: states() and states()[-1] == "pinned")

    # Stop clears the simulated location and reports stopped.
    await eng.handle({"cmd": "clear", "udid": "A"})
    assert device.calls[-1] == ("clear",), device.calls[-3:]
    assert states()[-1] == "stopped"

    # Invalid coordinates are rejected.
    try:
        await eng.handle({"cmd": "set", "udid": "B", "lat": 91, "lng": 0})
        raise AssertionError("accepted invalid latitude")
    except ValueError:
        pass

    print("engine tests passed")


asyncio.run(main())
