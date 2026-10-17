# Location+

A native macOS app that pins your iPhone's GPS to any point on the map. Built for iOS 17 and later, including iOS 27.

Click the map (or search for a place, or paste coordinates), choose your devices, and press **Pin Here**. The location stays until you press **Stop** or quit the app.

## Requirements

- macOS 26 or later
- Python 3.11+ (`brew install python@3.13`)
- An iPhone with **Developer Mode** on (Settings › Privacy & Security › Developer Mode)

## Build and install

```bash
./scripts/build-app.sh --install     # needs Xcode 26 / Swift 6.2
open "/Applications/Location+.app"
```

During development, `swift run` works too.

## First launch

Press **Set Up**. The app does two things, once:

1. Creates a private Python environment in `~/Library/Application Support/Location+/` and installs `pymobiledevice3` there.
2. Installs a launchd service (`com.hxbib.locationplus.tunneld`) that runs `pymobiledevice3 remote tunneld` as root. iOS 17+ needs this tunnel. You enter your password once. You won't need sudo again.

Then connect your iPhone with a cable, unlock it, and tap **Trust**.

## Using it

| | |
|---|---|
| Drop a pin | Click the map |
| Search | ⌘F, type a place or paste `40.6892, -74.0445` |
| Pin selected devices | ⌘↩ |
| Stop everything | ⌘. |
| Save / unsave place | ⌘D |

The menu bar icon shows what's pinned and has a stop button, so you can close the window. Quitting the app restores the real location.

## How it works

```
SwiftUI app  ──JSON lines over stdin/stdout──▶  engine/engine.py  ──▶  tunneld (root)  ──▶  iPhone
```

- `engine/engine.py` imports pymobiledevice3 directly. Each pinned device gets one long-lived DVT `LocationSimulation` channel. The channel is never restarted on a timer. Moving the pin reuses it, and a re-send every 10 s keeps it fresh and detects a drop. On a drop it reconnects with backoff (1 s → 15 s) and re-pins.
- The developer disk image is mounted automatically when needed (on iOS 27 it is installed over the tunnel).
- If the engine crashes, the app restarts it and re-pins. If the app goes away, the engine sees stdin close, clears every pin and exits.

## Troubleshooting

- **Engine log:** `~/Library/Logs/Location+/engine.log` (Location+ › Show Logs)
- **Tunnel log:** `/Library/Logs/LocationPlus-tunneld.log`
- **Device says "Connecting…":** keep the iPhone unlocked. Make sure Developer Mode is on and you've tapped Trust.
- **Remove everything:** Location+ › Uninstall Tunnel Service…, then delete `~/Library/Application Support/Location+`.
