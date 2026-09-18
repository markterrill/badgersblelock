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
silent. Changing the delay abandons any countdown already running.

The countdown starts only after three weak readings in a row, and it accumulates
time rather than running a single timer. A signal that recovers **pauses** it for
up to 5 seconds and then abandons it; it does not reset it. This matters: RSSI
swings about 15 dB, so the previous behaviour of resetting on every blip meant a
long delay could never elapse while you walked away, and the screen simply never
locked.

The no-signal timeout is 60 seconds: if the phone stops advertising altogether,
that counts as away. A Lock Delay longer than 60 seconds raises that timeout to
match, so picking 5 minutes does not get undercut by it.

**Return Threshold** (default **5 dB above the lock threshold**) is how strong the
signal must get for a phone that has been declared *away* to count as back —
which re-arms monitoring, and resumes it after you unlock with the phone out of
range. It has no part in the countdown; that is judged on the lock threshold
alone. It is chosen as an offset because it only means anything relative to the
lock threshold, and the menu shows the resulting absolute value.

Choosing 0 makes it identical to the lock threshold, so the phone counts as back
the instant it crosses the same line that declared it away. A signal resting near
that line then alternates between away and back. 0 is offered, but a few dB of
gap is what stops that.

The countdown judges weakness by the **lock threshold and nothing else**. Time
spent above it is not weak time, whatever the return threshold is set to.

Flapping around that line is handled by holding rather than resetting: a reading
back above the threshold pauses the countdown, keeping the time already
accumulated, and only abandons it after five continuous seconds back in range. A
real departure bounces back over the line for a second or two, not for five
unbroken seconds, so it still locks — while a phone lying on the desk near the
line never does.

Readings are smoothed over **4 seconds of time, not a fixed number of samples**.
While scanning, advertising packets can arrive several times a second, so a
5-sample window covered under a second and barely smoothed at all — which is how
a phone on the desk could read -48 one moment and -61 the next and start a
countdown.

The window is sized from the measured sample rate. Once the app has connected to
the phone it polls RSSI directly, so the rate is whatever the poll interval is
rather than the phone's advertising rate: at the original 2-second poll a
4-second window held only two readings. The poll is therefore **1 second**, which
gives the window about four readings — enough that one bad value cannot move the
mean far, without making the lock late. Each heartbeat line in the activity log
carries `samples_in_window` and `packets_per_sec` so this can be checked rather
than assumed.

Before any countdown starts, three conditions must all hold: the smoothed signal
has been below the lock threshold for **3 continuous seconds**, there are at
least three readings behind that average, and the window spans enough time to be
a real average. The duration matters as much as the count — while scanning,
three readings can arrive inside a single second, which once locked the screen
one second after launch off three readings taken before the connection had
settled.

For the same reason nothing locks until the app has **connected to the phone, or
10 seconds have passed**, whichever comes first. Early readings are taken while
still scanning and read far weaker than the truth; connecting ends that
condition, measured at about a second on a paired phone, so in normal use the
warm-up is over almost immediately. The 10 seconds are the backstop for when no
connection is established at all — which, if the phone really has gone, it will
not be. A held-off lock is logged as `warmup_hold` rather than passing in
silence.

Replaying a walk-away trace, the countdown starts about 7 seconds after the
signal genuinely crosses the threshold, so a 10-second delay locks roughly 17
seconds after you leave.

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

## Activity log

**Activity Log…** in the menu shows what the app has done: what happened, what it
did about it, and a traffic light — green normal, amber something delayed the
lock, red the lock did not happen, grey routine and not a fault (the radio going
down as the Mac sleeps, or a lock held off during the warm-up).

**Copy Diagnostics** puts the settings, the machine's capabilities and the recent
history on the clipboard in one go, which is the thing to paste when asking why a
lock did not fire.

The same lines are appended to `~/Library/Logs/BadgersBLELock/activity.log`, in a
format meant to be read by someone — or something — that has never seen this
source:

```
<iso8601> [LEVEL] <event> | <description> | <action> | <key=value ...>
```

Each session starts with a header of every setting that decides later lines, so
the file can be interpreted on its own. A run of identical events collapses to
its first and last line, the last carrying `(repeated N times over the last X
minutes)` — otherwise the 60-second heartbeat buries everything that matters.

At launch the file is trimmed to the **last 3 days**, by whole sessions: a
session is only intelligible alongside the header listing the settings that
produced it, and one that began four days ago but is still running is current
rather than stale.

Events are also mirrored to `os.Logger` under the subsystem
`local.badgersblelock`. Note that `log` is a zsh builtin, so the absolute path is
required:

```
/usr/bin/log show --predicate 'subsystem == "local.badgersblelock"' --last 1h
```

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
