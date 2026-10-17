# Location+

A native macOS app that pins your iPhone's GPS to any point on the map. Built for iOS 17 and later, including iOS 27.

Click the map (or search for a place, or paste coordinates), choose your devices, and press **Pin Here**. The location stays until you press **Stop** or quit the app.

## Install

1. Download **Location+.dmg** from the [latest release](../../releases/latest).
2. Open it and drag **Location+** onto **Applications**.
3. Open Location+ from Applications. The app isn't notarized by Apple, so the first time macOS blocks it:
   open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to Location+.
   (Or run `xattr -dr com.apple.quarantine "/Applications/Location+.app"` once.)

Requires macOS 26 or later on Apple silicon or Intel. On the iPhone, turn on **Developer Mode**
(Settings › Privacy & Security › Developer Mode).

## First launch

Press **Set Up**. It runs once:

1. **Engine.** Downloads a private, checksum-verified Python 3.13 and installs `pymobiledevice3` into
   `~/Library/Application Support/Location+/`. You don't need Homebrew. If the download fails, a Homebrew
   Python 3.11+ is used instead.
2. **Tunnel service.** Installs a launchd service (`com.hxbib.locationplus.tunneld`) that runs
   `pymobiledevice3 remote tunneld` as root, which iOS 17+ requires. You enter your password once and never need sudo again.

Then connect your iPhone with a cable, unlock it, and tap **Trust**.

Saved locations and history from the previous web version (`~/.locationplus/`) are imported automatically.
On a fresh install the original preset places are added. You can re-run both from **Settings › Places**.

## Build from source

```bash
./scripts/build-app.sh --install        # universal app into /Applications (Xcode 26 / Swift 6.2)
./scripts/build-app.sh --dmg            # build/Location+.dmg
swift run                               # development
python engine/test_engine.py            # engine tests against a fake device
```

## Using it

| | |
|---|---|
| Drop a pin | Click the map |
| Search | ⌘F, type a place or paste `40.6892, -74.0445` |
| Pin selected devices | ⌘↩ |
| Stop selected devices | ⌘⌫ |
| Stop everything | ⌘. |
| Copy coordinates | ⇧⌘C |
| Save / unsave place | ⌘D |

The menu bar icon shows what's pinned and has a stop button, so you can close the window. Quitting the app restores
the real location. Next launch offers to **Resume** the pins you had, including after a crash or power loss.
A pinned iPhone that gets unplugged, locked or rebooted is re-pinned automatically when it's reachable again.
The same happens after your Mac wakes from sleep.

## How it works

```
SwiftUI app  ──JSON lines over stdin/stdout──▶  engine/engine.py  ──▶  tunneld (root)  ──▶  iPhone
```

- `engine/engine.py` imports pymobiledevice3 directly. Each pinned device gets one long-lived DVT `LocationSimulation` channel. The channel is never restarted on a timer. Moving the pin reuses it, and a re-send every 10 s keeps it fresh and detects a drop. On a drop it reconnects with backoff (1 s → 15 s) and re-pins.
- The developer disk image is mounted automatically when needed (on iOS 27 it is installed over the tunnel).
- If the engine crashes, the app restarts it and re-pins. If the app goes away, the engine sees stdin close, clears every pin and exits.

## Troubleshooting

- **Engine log:** `~/Library/Logs/Location+/engine.log` (Help › Show Logs)
- **Tunnel log:** `/Library/Logs/LocationPlus-tunneld.log`
- **Device says "Connecting…":** keep the iPhone unlocked. Make sure Developer Mode is on and you've tapped Trust.
- **Engine keeps stopping:** Settings › Engine › Reinstall Engine.
- **Remove everything:** Settings › Tunnel Service › Uninstall, then delete `~/Library/Application Support/Location+` and the app.
