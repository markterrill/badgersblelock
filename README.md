# BadgersBLELock

A menu-bar app that locks this Mac when your phone walks away, using Bluetooth
signal strength. Lock-only — it never unlocks the machine for you, so it needs
no Accessibility permission, no stored password, and no keystroke injection.

## Build

Requires the Xcode Command Line Tools. **Full Xcode is not needed.**

```bash
./build.sh
open BadgersBLELock.app
```

macOS will ask for Bluetooth permission on first launch. The app has no Dock
icon; look for the padlock in the menu bar.

## Pairing

First launch opens the pairing wizard. It narrows a room full of Bluetooth
devices down to one phone by asking you to toggle Bluetooth off and on:

1. **Bluetooth on** — listens for 10s and records everything in range.
2. **Turn Bluetooth off** — anything still advertising is eliminated.
3. **Turn Bluetooth back on** — only devices that reappear survive.

Steps 2 and 3 repeat. Two cycles is usually enough even in a busy office. At
every stage the remaining candidates are listed, and the device whose name best
matches your account (`markterrill` ↔ *Mark's iPhone 14*) is marked **★ likely
yours** and pre-selected — you can accept it at any point instead of continuing.

**Your phone must be paired with this Mac.** An unpaired iPhone rotates its
Bluetooth identity every few minutes, so it cannot be tracked across a toggle.
The wizard detects this case and says so.

## Tuning

The one knob is the lock threshold, in the menu (default **-58 dBm**). Weaker
than that for 5 seconds and the screen locks.

RSSI does not map cleanly to metres — your body, walls, and pocket position
swing it by 15 dB. Calibrate by walking to where you want it to lock and reading
the live signal value off the menu.

There is 8 dB of hysteresis: after locking at -58, the phone must come back
above -50 to count as present, which stops it flapping at the boundary.

## How the lock happens

`Locker.lock()` resolves `SACLockScreenImmediate` from `login.framework` at
runtime via `dlopen`, so the app still launches if Apple removes it. The
fallback is sleeping the display through IOKit, which only locks if
**System Settings › Lock Screen › Require password immediately after sleep**
is enabled. Worth enabling either way.

## Layout

| File | Role |
|---|---|
| `ProximityMonitor.swift` | CoreBluetooth scanning, RSSI smoothing, presence state machine |
| `Locker.swift` | Screen locking and lock-state detection |
| `PairingWizard.swift` | Toggle-based elimination flow |
| `NameMatch.swift` | Fuzzy match of device names against the account name |
| `AppDelegate.swift` | Menu bar UI and preferences |
