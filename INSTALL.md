# Installing Badgers BLE Lock

Apple Silicon Mac, macOS 12 or later. (Start at Login needs macOS 13.)

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

## 4. Make the Mac recognise your phone

**Do not try to pair the phone under Settings › Bluetooth.** On current iOS that
does not work — the iPhone is not offered for pairing with a Mac there at all,
and waiting for it to appear is the single biggest time sink in this setup.

What works is connecting this Mac to the phone's **Personal Hotspot** once:
Wi-Fi menu › your iPhone, under the personal hotspot heading. You can disconnect
straight afterwards. The phone then shows up by name in the app's device list.

Being recognised is not cosmetic. An iPhone the Mac cannot identify deliberately
changes its Bluetooth address every few minutes — precisely to stop the sort of
tracking this app does — so it cannot be followed for more than a few minutes.

This is easiest when the phone and the Mac share an Apple ID. A phone on a
different Apple ID may not become recognisable at all; if its entry in the app's
list keeps changing, that is what is happening.

## 5. Find it in the menu bar

There is no Dock icon and no window — look for the **paw in the menu bar**, near
the clock. A silent launch looks like nothing happened; the paw is the app.

On first run the pairing wizard opens and walks you through identifying your phone
by toggling its Bluetooth off and on — each cycle discards the devices whose
presence did not follow the toggle, which narrows a busy office down fast. If the
phone is already listed by name, pick it from **Select Device** instead. Then tick
**Start at Login** in the menu so it survives a reboot.

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
  (how long it must stay weak, from 4 seconds to 5 minutes). Defaults are -58 dBm
  and 10 seconds. Walk to where you want it to lock and read the live signal off
  the menu. Handsets differ, so re-tune if you change phone.
- **Return Threshold** is how strong the signal must get before a phone that was
  declared away counts as back, set as an offset above the lock threshold
  (default 5 dB). It takes no part in the countdown.
- **Activity Log…** shows what the app did and why, with a traffic light per
  line. **Copy Diagnostics** in that window puts the settings and recent history
  on the clipboard — that is the thing to send when something misbehaves. Note it
  includes your phone's name and identifier.
- **About Badgers BLE Lock…** gives the version and a link to the releases page.
  The app does not update itself.
- **Turn on** System Settings › Lock Screen › *Require password immediately after
  sleep*. The app's fallback path relies on it.
- **Updating:** quit the app, drag the new one into Applications and choose
  Replace, then open it. Your paired phone and all settings are kept — they live
  in preferences, not in the app. Step 2 recurs for every new download, because
  the quarantine flag comes back. Step 3 may or may not; it has not been pinned
  down.
