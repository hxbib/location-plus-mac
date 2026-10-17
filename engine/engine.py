"""Location+ engine.

Long-lived helper process driven by the macOS app. Speaks JSON lines:

  app -> engine (stdin):   {"cmd": "set", "udid": ..., "lat": ..., "lng": ...}
                           {"cmd": "clear", "udid": ...}
                           {"cmd": "clear_all"}
                           {"cmd": "refresh"}   re-scan devices now
                           {"cmd": "kick"}      Mac woke up: re-assert every pin now
  engine -> app (stdout):  {"type": "ready", "version": ...}
                           {"type": "devices", "tunnel": bool, "devices": [...]}
                           {"type": "session", "udid": ..., "state": ..., ...}
                           {"type": "error", "message": ...}

Each pinned device gets one asyncio task that keeps a single DVT
LocationSimulation channel open. The channel is never torn down on purpose
while pinned (closing it is what restores real GPS); moving the pin reuses it.
When stdin closes (the app quit or crashed) every pin is cleared and we exit.
"""

import asyncio
import json
import logging
import math
import sys
from contextlib import suppress
from dataclasses import asdict, dataclass
from importlib.metadata import version
from typing import Any, Optional

from pymobiledevice3 import usbmux
from pymobiledevice3.exceptions import (
    AlreadyMountedError,
    DeveloperModeIsNotEnabledError,
    PasswordRequiredError,
    TunneldConnectionError,
)
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.services.mobile_image_mounter import auto_mount
from pymobiledevice3.tunneld.api import get_tunneld_tunnels

log = logging.getLogger("engine")

DEVICE_POLL_SECONDS = 3
KEEPALIVE_SECONDS = 10  # re-assert the coordinate; also how we notice a dead channel
MAX_BACKOFF_SECONDS = 15
CONNECT_TIMEOUT = 15
SET_TIMEOUT = 10
MOUNT_TIMEOUT = 300
IDENTIFY_INTERVAL = 10  # first mount downloads the developer disk image

DEV_MODE_OFF = "Developer Mode is off. Turn it on in Settings › Privacy & Security › Developer Mode."
UNREACHABLE = "iPhone isn't reachable. Keep it unlocked and connected."


def emit(msg: dict) -> None:
    try:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, OSError, ValueError):
        pass  # the app is gone; stdin EOF will shut us down


def describe_error(e: BaseException) -> str:
    if isinstance(e, DeveloperModeIsNotEnabledError):
        return DEV_MODE_OFF
    if isinstance(e, PasswordRequiredError):
        return "Unlock the iPhone and tap Trust."
    if isinstance(e, TunneldConnectionError):
        return "Tunnel service isn't running."
    if isinstance(e, asyncio.TimeoutError):
        return "The iPhone stopped responding."
    text = str(e).strip() or type(e).__name__
    return text.splitlines()[0][:200]


def is_wifi(entry: dict) -> bool:
    iface = str(entry.get("interface", ""))
    return "Network" in iface or iface.startswith("mobdev2")


async def connect_rsd(udid: str) -> RemoteServiceDiscoveryService:
    """Connect to the device's tunnel, preferring USB over Wi-Fi.

    Unlike tunneld.api.get_tunneld_device_by_udid this opens exactly one
    connection, so nothing leaks when a device has several tunnels.
    """
    tunnels = await get_tunneld_tunnels()
    entries = sorted(tunnels.get(udid, []), key=is_wifi)
    last: Optional[BaseException] = None
    for entry in entries:
        rsd = RemoteServiceDiscoveryService(
            (entry["tunnel-address"], entry["tunnel-port"]),
            name=entry.get("interface"),
            auxiliary_metadata=entry.get("auxiliary-metadata"),
        )
        try:
            await asyncio.wait_for(rsd.connect(), CONNECT_TIMEOUT)
            return rsd
        except Exception as e:
            last = e
            with suppress(Exception):
                await rsd.close()
    if last:
        log.info("connect %s failed: %r", udid, last)
    raise ConnectionError(UNREACHABLE)


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


class DeviceWatcher:
    def __init__(self) -> None:
        self.identity: dict[str, DeviceInfo] = {}
        self.usb_issue: dict[str, Optional[str]] = {}
        self.last_payload: Optional[str] = None
        self.wakeup = asyncio.Event()
        self.identifying: dict[str, asyncio.Task] = {}
        self.last_attempt: dict[str, float] = {}

    def _identify_soon(self, udid: str, tunneled: bool) -> None:
        """Identify in the background so a slow or untrusted device never stalls the scan.

        Rate-limited per device: re-asking every scan would also re-trigger the
        iPhone's "Trust This Computer?" prompt.
        """
        now = asyncio.get_running_loop().time()
        if udid in self.identifying or now - self.last_attempt.get(udid, -math.inf) < IDENTIFY_INTERVAL:
            return
        self.last_attempt[udid] = now

        async def work() -> None:
            try:
                await (self._identify_tunnel(udid) if tunneled else self._identify_usb(udid))
            except Exception as e:
                log.info("identify %s: %r", udid, e)
            finally:
                self.identifying.pop(udid, None)
                self.wakeup.set()

        self.identifying[udid] = asyncio.create_task(work())

    async def _identify_usb(self, udid: str) -> None:
        info = self.identity.get(udid) or DeviceInfo(udid=udid)
        issue = None
        try:
            lockdown = await asyncio.wait_for(create_using_usbmux(serial=udid, autopair=True), CONNECT_TIMEOUT)
            try:
                values = lockdown.all_values
                info.name = values.get("DeviceName") or info.name
                info.model = values.get("ProductType", "") or info.model
                info.os_version = values.get("ProductVersion", "") or info.os_version
                with suppress(Exception):
                    if not await lockdown.get_developer_mode_status():
                        issue = DEV_MODE_OFF
            finally:
                with suppress(Exception):
                    await lockdown.close()
            self.identity[udid] = info
        except Exception as e:
            issue = describe_error(e)
        self.usb_issue[udid] = issue

    async def _identify_tunnel(self, udid: str) -> None:
        rsd = await connect_rsd(udid)
        try:
            values = rsd.all_values or {}
            self.identity[udid] = DeviceInfo(
                udid=udid,
                name=values.get("DeviceName") or "iPhone",
                model=rsd.product_type or "",
                os_version=rsd.product_version,
            )
        finally:
            with suppress(Exception):
                await rsd.close()

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
            tunneled = bool(tunnels.get(udid))
            m = mux.get(udid)
            if udid not in self.identity and tunneled:
                self._identify_soon(udid, tunneled=True)
            elif m is not None and not tunneled and (udid not in self.identity or self.usb_issue.get(udid)):
                # Re-check untunneled devices so a fixed issue (trusted,
                # Developer Mode enabled) clears by itself.
                self._identify_soon(udid, tunneled=False)

            d = DeviceInfo(**asdict(self.identity.get(udid) or DeviceInfo(udid=udid)))
            if tunneled:
                d.connection = "Wi-Fi" if all(is_wifi(t) for t in tunnels[udid]) else "USB"
            else:
                d.connection = "USB" if (m and m.is_usb) else "Wi-Fi"
            d.ready = tunneled
            if not tunneled:
                d.issue = (self.usb_issue.get(udid)
                           or ("Tunnel service isn't running." if not tunnel_ok
                               else "Connecting… keep the iPhone unlocked."))
            devices.append(d)

        payload = json.dumps({"type": "devices", "tunnel": tunnel_ok,
                              "devices": [asdict(d) for d in devices]})
        if payload != self.last_payload:
            self.last_payload = payload
            try:
                sys.stdout.write(payload + "\n")
                sys.stdout.flush()
            except (BrokenPipeError, OSError, ValueError):
                pass

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
        self.opened = False
        self.last_mount = -math.inf
        self.task = asyncio.create_task(self.run())

    def report(self, state: str, error: Optional[str] = None, detail: Optional[str] = None) -> None:
        if self.stopping:
            return  # a stopped session must not overwrite a newer one's status
        emit({"type": "session", "udid": self.udid, "state": state,
              "lat": self.lat, "lng": self.lng, "error": error, "detail": detail})

    def move(self, lat: float, lng: float) -> None:
        self.lat, self.lng = lat, lng
        self.changed.set()

    def kick(self) -> None:
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
        await asyncio.wait_for(sim.set(self.lat, self.lng), SET_TIMEOUT)
        self.report("pinned")
        try:
            while not self.stopping:
                self.changed.clear()
                with suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(self.changed.wait(), KEEPALIVE_SECONDS)
                if self.stopping:
                    break
                moved = self.changed.is_set()
                lat, lng = self.lat, self.lng
                await asyncio.wait_for(sim.set(lat, lng), SET_TIMEOUT)
                if moved:
                    self.report("pinned")
        finally:
            if self.stopping:
                with suppress(Exception):
                    await asyncio.wait_for(sim.clear(), 3)

    async def _open_and_hold(self, rsd: RemoteServiceDiscoveryService) -> None:
        self.opened = False
        async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as sim:
            self.opened = True
            self.backoff = 1.0
            await self._hold(sim)

    async def _connect_and_hold(self) -> None:
        rsd = await connect_rsd(self.udid)
        try:
            try:
                await self._open_and_hold(rsd)
                return
            except DeveloperModeIsNotEnabledError:
                raise
            except Exception as first_error:
                # Only a failure to *open* the channel suggests the developer
                # disk image is missing (first use, or the iPhone rebooted); a
                # channel that died mid-hold doesn't. Rate-limited so a device
                # that fails for another reason doesn't remount in a loop.
                now = asyncio.get_running_loop().time()
                if self.opened or self.stopping or now - self.last_mount < 120:
                    raise
                log.info("DVT unavailable on %s (%r); mounting developer image", self.udid, first_error)
            self.last_mount = asyncio.get_running_loop().time()
            self.report("connecting", detail="Preparing developer tools on the iPhone…")
            try:
                await asyncio.wait_for(auto_mount(rsd), MOUNT_TIMEOUT)
            except AlreadyMountedError:
                pass
            except Exception as e:
                log.warning("auto_mount %s: %r", self.udid, e)
                raise RuntimeError(
                    "Couldn't prepare developer tools on the iPhone. The first time needs an internet "
                    f"connection. ({describe_error(e)})") from e
        finally:
            with suppress(Exception):
                await rsd.close()
        # Fresh connection after mounting so the new services are visible.
        rsd = await connect_rsd(self.udid)
        try:
            await self._open_and_hold(rsd)
        finally:
            with suppress(Exception):
                await rsd.close()

    async def run(self) -> None:
        self.backoff = 1.0
        self.report("connecting")
        while not self.stopping:
            try:
                await self._connect_and_hold()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                if self.stopping:
                    break
                log.warning("session %s: %r", self.udid, e)
                self.report("reconnecting", describe_error(e))
                self.changed.clear()
                with suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(self.changed.wait(), self.backoff)
                self.backoff = min(self.backoff * 2, MAX_BACKOFF_SECONDS)


# ─── Main loop ──────────────────────────────────────────────────────────────

def parse_coordinate(msg: dict[str, Any]) -> tuple[float, float]:
    lat, lng = float(msg["lat"]), float(msg["lng"])
    if not (math.isfinite(lat) and math.isfinite(lng) and -90 <= lat <= 90 and -180 <= lng <= 180):
        raise ValueError(f"Invalid coordinate: {lat}, {lng}")
    return lat, lng


class Engine:
    def __init__(self) -> None:
        self.sessions: dict[str, PinSession] = {}
        self.watcher = DeviceWatcher()

    async def handle(self, msg: dict) -> None:
        cmd = msg.get("cmd")
        if cmd == "set":
            udid = str(msg["udid"])
            lat, lng = parse_coordinate(msg)
            session = self.sessions.get(udid)
            if session and not session.stopping:
                session.move(lat, lng)
            else:
                self.sessions[udid] = PinSession(udid, lat, lng)
        elif cmd == "clear":
            udid = str(msg["udid"])
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
        elif cmd == "kick":
            for session in self.sessions.values():
                session.kick()
            self.watcher.wakeup.set()

    async def clear_all(self) -> None:
        sessions, self.sessions = list(self.sessions.values()), {}
        await asyncio.gather(*(s.stop() for s in sessions), return_exceptions=True)
        for s in sessions:
            if s.udid not in self.sessions:
                emit({"type": "session", "udid": s.udid, "state": "stopped"})

    async def run(self) -> None:
        loop = asyncio.get_running_loop()
        reader = asyncio.StreamReader(limit=1 << 20)
        await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
        watcher_task = asyncio.create_task(self.watcher.run())
        emit({"type": "ready", "version": version("pymobiledevice3")})
        pending: set[asyncio.Task] = set()
        while True:
            try:
                line = await reader.readline()
            except (ValueError, asyncio.LimitOverrunError):
                continue
            if not line:
                break
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if not isinstance(msg, dict):
                continue
            # Commands run concurrently so a slow stop never blocks a new pin.
            task = asyncio.create_task(self._safe_handle(msg))
            pending.add(task)
            task.add_done_callback(pending.discard)
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
    with suppress(KeyboardInterrupt):
        asyncio.run(Engine().run())


if __name__ == "__main__":
    main()
