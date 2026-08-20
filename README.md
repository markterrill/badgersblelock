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
icon; look for the badger paw in the menu bar:

| Paw | Meaning |
|---|---|
| Green | Phone present |
| Red | Phone missing, lock countdown running |
| Amber | Phone missing, but you unlocked anyway — locking is paused |
| Grey, slashed | Monitoring switched off |

## Pairing

First launch opens the pairing wizard. It narrows a room full of Bluetooth
devices down to one phone by asking you to toggle Bluetooth off and on:

1. **Bluetooth on** — listens for 10s and records everything in range.
2. **Turn Bluetooth off** — anything still advertising is eliminated.
3. **Turn Bluetooth back on** — only devices that reappear survive.

Steps 2 and 3 repeat. Two cycles is usually enough even in a busy office. At
every stage the remaining candidates are listed, and the device whose name best
matches your account (`bobsmith` ↔ *Bob's iPhone 14*) is marked **★ likely
yours** and pre-selected — you can accept it at any point instead of continuing.

The **Select Device** menu only lists devices at -55 dBm or stronger — your
phone is on the desk in front of you when you pair it, so anything weaker is
someone else's hardware. The device you have selected stays listed however weak
it gets, so you can always see what is being monitored.

**Your phone must be paired with this Mac.** An unpaired iPhone rotates its
Bluetooth identity every few minutes, so it cannot be tracked across a toggle.
The wizard detects this case and says so.

## Tuning

Two knobs, both in the menu.

**Lock Threshold** (default **-58 dBm**) is how weak the signal has to get to
count as away.

**Lock Delay** (default **10 seconds**) is how long it has to stay that weak
before the screen actually locks — 4 seconds through to 5 minutes. The paw turns
red as soon as the countdown starts, so a long delay is still visible rather than
silent. Changing the delay cancels any countdown already running.

The no-signal timeout is 60 seconds: if the phone stops advertising altogether,
that counts as away. A Lock Delay longer than 60 seconds raises that timeout to
match, so picking 5 minutes does not get undercut by it.

RSSI does not map cleanly to metres — your body, walls, and pocket position
swing it by 15 dB. Calibrate by walking to where you want it to lock and reading
the live signal value off the menu.

There is 8 dB of hysteresis: after locking at -58, the phone must come back
above -50 to count as present, which stops it flapping at the boundary.

## Unlocking while your phone is away

Unlocking by hand is taken as a statement: *I am here, my phone is not.* Locking
pauses at that point rather than throwing you straight back out, and the paw goes
amber. It re-arms itself as soon as the phone is back in range — so unlike
switching the app off, this cannot quietly leave you unprotected. Toggling
**Enabled**, or picking a device, also re-arms it immediately.

The pause is deliberately not written to preferences. It describes the session
you are in, and persisting it would mean one phoneless unlock disarmed the app
for good.

Coming back into range needs three readings in a row above the return threshold,
spanning at least three seconds. A single strong packet used to be enough, and
because RSSI swings about 15 dB at the edge of range, stray spikes re-armed the
state machine and locked the screen once per spike.

## Start at Login

The **Start at Login** menu item registers the app with `SMAppService`, so it
comes back after a reboot. It keeps no preference of its own — the checkmark is
read from the system, so switching it off in **System Settings › General › Login
Items** cannot disagree with what the menu shows. Needs macOS 13; on 12 the item
is simply absent.

Registration records a path, so keep the app somewhere stable —
**/Applications**, not a build directory. Rebuilding in place invalidates it.

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
| `PawIcon.swift` | The menu bar paw glyph, drawn as vectors |
| `MenuHeader.swift` | Large paw and app name at the top of the menu |
