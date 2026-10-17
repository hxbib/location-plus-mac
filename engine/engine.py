"""Location+ engine.

Long-lived helper process driven by the macOS app. Speaks JSON lines:

  app -> engine (stdin):   {"cmd": "set", "udid": ..., "lat": ..., "lng": ...}
                           {"cmd": "clear", "udid": ...}
                           {"cmd": "clear_all"}
                           {"cmd": "refresh"}
  engine -> app (stdout):  {"type": "devices", "tunnel": bool, "devices": [...]}
                           {"type": "session", "udid": ..., "state": ..., ...}

Each pinned device gets one asyncio task that keeps a single DVT
LocationSimulation channel open. The channel is never torn down on purpose
while pinned (closing it is what restores real GPS); moving the pin reuses it.
When stdin closes (the app quit or crashed) every pin is cleared and we exit.
"""

import asyncio
import json
import logging
import sys
from contextlib import suppress
from dataclasses import dataclass
from typing import Optional

from pymobiledevice3 import usbmux
from pymobiledevice3.exceptions import (
    AlreadyMountedError,
    DeveloperModeIsNotEnabledError,
    PasswordRequiredError,
    TunneldConnectionError,
)
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.services.mobile_image_mounter import auto_mount
from pymobiledevice3.tunneld.api import get_tunneld_device_by_udid, get_tunneld_tunnels

log = logging.getLogger("engine")

DEVICE_POLL_SECONDS = 3
KEEPALIVE_SECONDS = 10  # re-assert the coordinate; also how we notice a dead channel
MAX_BACKOFF_SECONDS = 15


def emit(msg: dict) -> None:
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def describe_error(e: BaseException) -> str:
    if isinstance(e, DeveloperModeIsNotEnabledError):
        return "Developer Mode is off. Turn it on in Settings › Privacy & Security."
    if isinstance(e, PasswordRequiredError):
        return "Unlock the iPhone and tap Trust."
    if isinstance(e, TunneldConnectionError):
        return "Tunnel service isn't running."
    text = str(e).strip() or type(e).__name__
    return text.splitlines()[0][:200]


# ─── Device discovery ───────────────────────────────────────────────────────

@dataclass
class DeviceInfo:
    udid: str
    name: str = "iPhone"
    model: str = ""
    os_version: str = ""
    connection: str = ""  # "USB" | "Wi-Fi"
    ready: bool = False
    issue: Optional[str] = None

    def to_json(self) -> dict:
        return self.__dict__.copy()


class DeviceWatcher:
    def __init__(self) -> None:
        self.info_cache: dict[str, DeviceInfo] = {}
        self.last_payload: Optional[str] = None
        self.wakeup = asyncio.Event()

    async def _identify_usb(self, udid: str) -> DeviceInfo:
        info = DeviceInfo(udid=udid)
        try:
            lockdown = await create_using_usbmux(serial=udid, autopair=True)
            try:
                values = lockdown.all_values
                info.name = values.get("DeviceName", info.name)
                info.model = values.get("ProductType", "")
                info.os_version = values.get("ProductVersion", "")
                if not await lockdown.get_developer_mode_status():
                    info.issue = "Developer Mode is off. Turn it on in Settings › Privacy & Security."
            finally:
                await lockdown.close()
        except Exception as e:
            info.issue = describe_error(e)
        return info

    async def _identify_tunnel(self, udid: str) -> DeviceInfo:
        info = DeviceInfo(udid=udid)
        rsd = await get_tunneld_device_by_udid(udid)
        if rsd is None:
            return info
        try:
            values = rsd.all_values
            info.name = values.get("DeviceName", info.name)
            info.model = rsd.product_type or ""
            info.os_version = rsd.product_version
        finally:
            await rsd.close()
        return info

    async def scan(self) -> None:
        tunnel_ok = True
        try:
            tunnels = await get_tunneld_tunnels()
        except TunneldConnectionError:
            tunnel_ok, tunnels = False, {}

        try:
            mux = {d.serial: d for d in await usbmux.list_devices()}
        except Exception:
            mux = {}

        devices: list[DeviceInfo] = []
        for udid in sorted(set(tunnels) | set(mux)):
            cached = self.info_cache.get(udid)
            tunneled = udid in tunnels
            # Identify once per device; re-identify untunneled USB devices so a
            # fixed issue (trusted, Developer Mode enabled) clears itself.
            if cached is None or (not tunneled and cached.issue):
                try:
                    cached = await (self._identify_tunnel(udid) if tunneled and udid not in mux
                                    else self._identify_usb(udid))
                except Exception as e:
                    cached = DeviceInfo(udid=udid, issue=describe_error(e))
                self.info_cache[udid] = cached
            d = DeviceInfo(**cached.to_json())
            m = mux.get(udid)
            d.connection = "USB" if (m and m.is_usb) else "Wi-Fi"
            d.ready = tunneled
            if tunneled:
                d.issue = None
            elif not d.issue:
                d.issue = ("Tunnel service isn't running." if not tunnel_ok
                           else "Connecting… keep the iPhone unlocked.")
            devices.append(d)

        payload = json.dumps({"type": "devices", "tunnel": tunnel_ok,
                              "devices": [d.to_json() for d in devices]})
        if payload != self.last_payload:
            self.last_payload = payload
            sys.stdout.write(payload + "\n")
            sys.stdout.flush()

    async def run(self) -> None:
        while True:
            try:
                await self.scan()
            except Exception:
                log.exception("device scan failed")
            self.wakeup.clear()
            with suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self.wakeup.wait(), DEVICE_POLL_SECONDS)


# ─── Pin sessions ───────────────────────────────────────────────────────────

class PinSession:
    def __init__(self, udid: str, lat: float, lng: float) -> None:
        self.udid = udid
        self.lat, self.lng = lat, lng
        self.changed = asyncio.Event()
        self.stopping = False
        self.task = asyncio.create_task(self.run())

    def report(self, state: str, error: Optional[str] = None) -> None:
        if self.stopping:
            return  # a stopped session must not overwrite a newer one's status
        emit({"type": "session", "udid": self.udid, "state": state,
              "lat": self.lat, "lng": self.lng, "error": error})

    def move(self, lat: float, lng: float) -> None:
        self.lat, self.lng = lat, lng
        self.changed.set()

    async def stop(self) -> None:
        self.stopping = True
        self.changed.set()
        try:
            await asyncio.wait_for(asyncio.shield(self.task), 8)
        except (asyncio.TimeoutError, Exception):
            self.task.cancel()

    async def _hold(self, sim: LocationSimulation) -> None:
        if self.stopping:
            return
        await sim.set(self.lat, self.lng)
        self.report("pinned")
        while not self.stopping:
            self.changed.clear()
            with suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self.changed.wait(), KEEPALIVE_SECONDS)
            if self.stopping:
                break
            moved = self.changed.is_set()
            await sim.set(self.lat, self.lng)
            if moved:
                self.report("pinned")
        with suppress(Exception):
            await asyncio.wait_for(sim.clear(), 3)

    async def run(self) -> None:
        backoff = 1.0
        first = True
        while not self.stopping:
            if first:
                self.report("connecting")
            try:
                rsd = await get_tunneld_device_by_udid(self.udid)
                if rsd is None:
                    raise ConnectionError("iPhone isn't reachable. Keep it unlocked and connected.")
                try:
                    try:
                        await auto_mount(rsd)
                    except AlreadyMountedError:
                        pass
                    except Exception as e:  # DVT may still work; let it decide
                        log.warning("auto_mount %s: %s", self.udid, e)
                    async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as sim:
                        backoff = 1.0
                        await self._hold(sim)
                finally:
                    with suppress(Exception):
                        await rsd.close()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                if self.stopping:
                    break
                log.warning("session %s: %r", self.udid, e)
                self.report("reconnecting", describe_error(e))
                self.changed.clear()
                with suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(self.changed.wait(), backoff)
                backoff = min(backoff * 2, MAX_BACKOFF_SECONDS)
            first = False


# ─── Main loop ──────────────────────────────────────────────────────────────

class Engine:
    def __init__(self) -> None:
        self.sessions: dict[str, PinSession] = {}
        self.watcher = DeviceWatcher()

    async def handle(self, msg: dict) -> None:
        cmd = msg.get("cmd")
        if cmd == "set":
            udid, lat, lng = msg["udid"], float(msg["lat"]), float(msg["lng"])
            session = self.sessions.get(udid)
            if session and not session.stopping:
                session.move(lat, lng)
            else:
                self.sessions[udid] = PinSession(udid, lat, lng)
        elif cmd == "clear":
            udid = msg["udid"]
            session = self.sessions.pop(udid, None)
            if session:
                await session.stop()
            if udid not in self.sessions:  # not re-pinned while we were stopping
                emit({"type": "session", "udid": udid, "state": "stopped"})
        elif cmd == "clear_all":
            await self.clear_all()
        elif cmd == "refresh":
            self.watcher.last_payload = None
            self.watcher.wakeup.set()

    async def clear_all(self) -> None:
        sessions, self.sessions = list(self.sessions.values()), {}
        await asyncio.gather(*(s.stop() for s in sessions), return_exceptions=True)
        for s in sessions:
            if s.udid not in self.sessions:
                emit({"type": "session", "udid": s.udid, "state": "stopped"})

    async def run(self) -> None:
        loop = asyncio.get_running_loop()
        reader = asyncio.StreamReader()
        await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
        watcher_task = asyncio.create_task(self.watcher.run())
        emit({"type": "ready"})
        while line := await reader.readline():
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            # Commands run concurrently so a slow stop never blocks a new pin.
            asyncio.create_task(self._safe_handle(msg))
        log.info("stdin closed; clearing pins")
        watcher_task.cancel()
        await self.clear_all()

    async def _safe_handle(self, msg: dict) -> None:
        try:
            await self.handle(msg)
        except Exception as e:
            log.exception("command failed: %s", msg)
            emit({"type": "error", "message": describe_error(e)})


def main() -> None:
    logging.basicConfig(stream=sys.stderr, level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("pymobiledevice3").setLevel(logging.WARNING)
    asyncio.run(Engine().run())


if __name__ == "__main__":
    main()
