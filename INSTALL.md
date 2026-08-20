# Installing Badgers BLE Lock

Apple Silicon Mac, macOS 13 or later.

## 1. Install

Unzip and drag **BadgersBLELock.app** to your **Applications** folder. Keep it
there — the Start at Login setting records the app's location, so running it from
your Downloads folder will break when you move or replace it.

## 2. Get past Gatekeeper

The app is signed locally rather than through Apple's notarisation service, so
macOS blocks it the first time. This is expected:

1. Double-click the app. macOS refuses to open it.
2. Open **System Settings › Privacy & Security**.
3. Scroll down to the message about BadgersBLELock and click **Open Anyway**.
4. Confirm.

You only do this once per version.

## 3. Allow Bluetooth

Say yes when macOS asks for Bluetooth. Without it the app cannot measure how far
away your phone is, and it will not work at all. If you miss the prompt, enable it
under **System Settings › Privacy & Security › Bluetooth**.

## 4. Pair your phone first

**Your phone must already be paired with this Mac** — Settings › Bluetooth on the
phone, pair with the Mac. An unpaired iPhone changes its Bluetooth identity every
few minutes and cannot be tracked.

## 5. Find it and pair

There is no Dock icon and no window — look for the **paw in the menu bar**, near
the clock. A silent launch looks like nothing happened; the paw is the app.

On first run the pairing wizard opens and walks you through identifying your phone
by toggling its Bluetooth off and on. Then tick **Start at Login** in the menu so
it survives a reboot.

## What the paw colours mean

| Paw | Meaning |
|---|---|
| Green | Phone present |
| Red | Phone missing, lock countdown running |
| Amber | Phone missing, but you unlocked anyway — locking is paused until it returns |
| Grey, slashed | Monitoring switched off |

## Worth knowing

- **It only locks, never unlocks.** No stored password, no Accessibility access.
- **Tune it** with Lock Threshold (how weak the signal must get) and Lock Delay
  (how long it must stay weak). Defaults are -58 dBm and 10 seconds. Walk to
  where you want it to lock and read the live signal off the menu.
- **Turn on** System Settings › Lock Screen › *Require password immediately after
  sleep*. The app's fallback path relies on it.
- New versions repeat steps 2 and 3, because the signature changes each build.
