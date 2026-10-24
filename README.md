# BrightSync

A small macOS menu bar app that keeps the brightness of your external monitors
in step: pick one display as the source, and the others follow it over DDC/CI.

Useful when one monitor changes brightness on its own or by itself — an ambient
light sensor doing its thing, or the keyboard brightness keys only reaching one
screen — and you want the rest of the desk to match.

- One source display, any number of followers
- Or follow an ambient light sensor (Philips Hue motion sensors to start with)
  through a brightness curve you shape from the menu (see
  [Following an ambient light sensor](#following-an-ambient-light-sensor))
- Optionally mirrors the color preset (color temperature) as well
- The source can be any connected display, not just the main one
- Checks every 10 seconds to 2 minutes (your choice; 30 seconds by default)
- Stays off the display bus while displays sleep, wake or change (see
  [Staying out of the way](#staying-out-of-the-way))
- Proportional, not literal: a panel whose range is 0–80 is set to the same
  *percentage*, not the same raw number
- No Dock icon, one small binary, and no permissions unless you pair a Hue
  bridge, which needs local network access

## Requirements

- Apple Silicon Mac, macOS 13 or later
- Displays reachable over DDC/CI. DisplayPort, USB-C and Thunderbolt are the
  reliable paths. Over a Mac's built-in HDMI port, DDC *reads* fail on some
  Mac and monitor combinations even though writes succeed — if a display shows
  as `unreadable`, try connecting it over USB-C/Thunderbolt instead. BrightSync
  backs off from a display it cannot read, so an unreadable display costs a
  read every half hour at most, not one per round.

## Install

Build it from source. No Xcode needed, just the Swift toolchain that ships
with the Command Line Tools (`xcode-select --install`):

```sh
git clone https://github.com/m-torun/brightsync.git
cd brightsync
./build.sh
cp -R BrightSync.app /Applications/
open /Applications/BrightSync.app
```

An app built on your own Mac opens without any Gatekeeper prompt.

The first build creates a code signing certificate called "BrightSync Local
Signing" in your login keychain, and every build on that Mac is signed with
it. macOS remembers some permissions by an app's signature, and an ad-hoc
signature changes with every build; with this one, local network access (for
the Hue bridge) carries over from build to build. The Keychain is stricter:
for apps not signed by an Apple-issued certificate it also tracks the exact
build, so after each update BrightSync asks once more to read its Hue key.
The certificate never leaves your Mac. To sign ad hoc instead, build with
`BRIGHTSYNC_ADHOC=1 ./build.sh`; to remove the certificate, delete it in
Keychain Access.

The [latest release](https://github.com/m-torun/brightsync/releases/latest)
has the same app prebuilt. It is signed ad hoc rather than with an Apple
Developer ID and is not notarized, so macOS refuses to open it, saying it
cannot verify that the app is free of malware. If you would rather not build,
allow it once under System Settings → Privacy & Security → **Open Anyway**.

## Using it

A sun icon appears in the menu bar. The menu is kept short: what brightness is
following (with a brightness slider when that is a light sensor), a switch to
pause syncing, and **Settings…**.

The Settings window holds the rest: what brightness follows, how often a
source display is checked, which display the color preset is copied from, the
displays and their current brightness, light sensors and pairing, and
**Start at login**.

The first line of the menu says when BrightSync is holding off, for example
`Paused: displays asleep` or `Waiting for displays to settle (42 s)`. It waits
a minute after launch before talking to any display.

## Checking what it sees

```sh
/Applications/BrightSync.app/Contents/MacOS/BrightSync --list
```

```
STUDIO DISPLAY  id=1  brightness=72/100
  key: <EDID UUID>
ACME 27  id=2  brightness=58/100
  key: <EDID UUID>
```

`--read` reads any other VCP codes once from each display, for example
`--read 0x14 0x0C` for the color preset and color temperature.

Displays are remembered by EDID UUID, so your choice of source survives
reboots and reconnection, where display IDs do not.

## Following an ambient light sensor

Brightness can follow an ambient light sensor instead of a display. That
helps when a monitor's own sensor will not go as bright or as dim as you want,
or when no monitor has one. BrightSync ships with support for the light sensor
in Philips Hue motion sensors.

1. In Settings, under **Light sensors**, click **Pair a Bridge…**, press the
   round link button on top of the bridge, and click **Pair** within 30 seconds.
   macOS asks whether BrightSync may find devices on your local network; it
   needs that to reach the bridge. The key the bridge hands out is kept in your
   login Keychain.
2. Choose the sensor under **Brightness → Follow**. Put it where it sees the
   room's light but not the screens, or it will measure the monitors.
3. Turn off the monitors' own auto-brightness, or they will fight it.

The bridge pushes a new reading as soon as the light changes (every few seconds
while it is changing), so nothing is polled. Every display follows the sensor,
including a single one. While BrightSync is holding off (after a wake or a
display change, during a call), the slider's caption says so and counts down;
whatever you set is applied when it may send again.

### Brighter or dimmer than the default

Out of the box, brightness rises 25 points for every tenfold increase in
light: 10% at 1 lux, 60% at 100 lux, 100% from about 1800 lux. The slider in
the menu moves that up or down, from -50 to +50 points, at every light level:
at +10 the monitors are always 10 points brighter than the default, whatever
the light. 0 is the default, and the slider snaps to it when you get close.

**Adjust monitors together** works like the SYNC button of a car's climate
control. When it is on, one slider moves every monitor. When it is off, each
monitor gets its own slider, starting from the shared value, so two panels
that look different at the same percentage can be evened out. Settings shows
the light, the default for it, each monitor's offset and the brightness it
ends up with, and **Reset to Default** puts everything back to 0.

### Checking the sensors

```sh
/Applications/BrightSync.app/Contents/MacOS/BrightSync --sensors 60
```

lists the light sensors on paired bridges with their readings, then prints each
new reading for 60 seconds.

### Adding another kind of sensor

A kind of sensor is a class that implements `LightSensorProvider`
(`Sources/BrightSync/LightSensor.swift`) and is listed in
`AmbientController.providers`. It reports its sensors with a stable ID, a name
and the latest reading in lux, calls `onChange` when anything changes, and
never prompts on its own. The Hue provider (`Sources/BrightSync/Hue/`) is the
reference: Bonjour discovery, pairing, the key in the Keychain, certificate
pinning, and an event stream that reconnects with back-off.

## Color temperature

Under **Color preset** in Settings, BrightSync can also copy VCP `0x14`
(select color preset) from one display to the others. It is off by default.
The color source is chosen separately from the brightness source, so
brightness can follow a light sensor while the color preset follows a
monitor.

This is best-effort by nature, and worth understanding before relying on it:

- A color preset is an *enumerated* value, so it is copied verbatim rather
  than scaled the way brightness is.
- Preset numbering is only nominally standard (`0x05` is 6500K, `0x08` is
  9300K, and so on). Vendors deviate, so the same number can mean different
  things on two monitors.
- Preset lists are often **sparse**. A display may ignore a value it does not
  implement, or silently substitute another one — in testing, one monitor
  accepted presets 5 and 8, ignored 4, and turned 6 into 1.

BrightSync therefore reads the value back after writing it. If the display
did not take it, that value is remembered as unsupported for that display and
is not written again, so an unsupported preset cannot cause an endless rewrite
loop. Reconnecting a display clears those memories.

Note that on some monitors each color preset carries its own brightness, so
changing the preset can change brightness too.

## How it works

Each round, BrightSync reads VCP feature `0x10` (brightness) from the source,
converts it to a fraction of that display's maximum, and writes the equivalent
value to each other display. The other displays are read once, after they
appear and settle, to learn their range; after that they are only written to,
and only when the value moves by more than one point. Monitors persist
brightness to internal storage, which has a finite number of write cycles.

In a steady state that is one DDC read per round (two with color sync on) and
no writes. With a single display, or with sync switched off, BrightSync sends
nothing at all.

When following a light sensor there are no periodic reads at all. Each
display is read once, the first time it is seen, to learn its brightness
range, which is remembered across wakes and launches. After that a new target
is a single write, sent only when it moves by more than a point (by any amount
when you move the slider). A slider being
dragged is coalesced into at most one round every tenth of a second.

All DDC traffic runs on a background queue; a single read takes roughly 100 ms.

## Staying out of the way

On Apple Silicon every DDC transaction goes through the display coprocessor
(DCP), the same firmware that handles display sleep, wake and mode changes.
DDC traffic at those moments has been linked to display hangs and system
freezes ([Lunar FAQ](https://lunar.fyi/faq#apply-wake),
[BetterDisplay discussion](https://github.com/waydabber/BetterDisplay/discussions/2622)).
So BrightSync holds off:

- **While the displays or the Mac sleep**, the screen is locked, or another
  user's session is active. No timer runs at all while held.
- **Before the Mac sleeps.** macOS waits for BrightSync's answer before going
  to sleep, so the gate closes and any transaction already on the wire
  finishes first (a few hundred milliseconds at most).
- **Before the displays sleep for inactivity.** macOS only announces display
  sleep once it has happened, so BrightSync stops sending 15 seconds before
  the display sleep timer runs out, unless something such as a video is
  keeping the screen awake.
- **During calls.** While any app uses the camera or microphone, nothing is
  sent; brightness catches up when the call ends. A video call with many
  tiles keeps the display coprocessor at its busiest. This is on by default
  (**Pause during calls** in Settings → General); reading whether the devices
  are in use needs no permission and does not open them.
- **Around any display change.** macOS calls BrightSync before and after every
  reconfiguration (plugging, unplugging, mode changes, the reconnects some
  monitors go through on wake). Each one restarts a 60-second quiet period,
  and nothing is sent until it ends. The same quiet period follows wake and
  launch.
- **Mid-round.** The checks run before every single transaction, so an event
  that arrives during a round stops the rest of it.
- **For a display macOS reports as asleep or offline**, even when the others
  are awake.
- **After a failure.** Nothing is retried on the spot. When a request cannot
  be sent or gets no reply, that display is left alone for twice the
  interval, then four times, up to half an hour; a successful transaction or
  **Sync Now** resets it. When the display answers with an unusable reply,
  the link works and only that reading is lost: it is read again next round,
  then less and less often, while writes to that display carry on.

What is left: macOS cannot announce a monitor that drops off by itself (a
cable pulled mid-transaction, say), or display sleep you trigger yourself (a
hot corner, a keyboard shortcut), so a transaction already under way, about
100 to 200 ms, can still meet one.

## Settings and privacy

Settings are stored in your own `UserDefaults` under
`app.brightsync.BrightSync` (source display or sensor, interval, enabled,
deadband, color temperature syncing, your brightness curves, and the last
address of each Hue bridge). Hue keys are in your login Keychain under
"BrightSync Hue".
Nothing is written into this repository. The app makes no network requests
unless you pair a Hue bridge, and then only to that bridge on your local
network, after checking its certificate against Philips' own CA.

## Notes and limits

- A monitor's own auto-brightness feature keeps adjusting the panel. That is
  fine, and is in fact a nice way to use this: make that monitor the source and
  the others will follow its sensor.
- When following a light sensor, turn the monitors' own auto-brightness off;
  otherwise both keep adjusting the same panel.
- A monitor's auto-brightness switch is usually *not* a DDC feature. On Dell
  UltraSharps, for example, it is controlled over USB HID by Dell Display and
  Peripheral Manager, so BrightSync cannot turn it on or off — use the vendor's
  app or the monitor's own menu for that.
- When a display disappears — switched to another computer by a KVM, or
  unplugged — BrightSync notices and resumes a minute after it comes back.

## Log

`~/Library/Logs/BrightSync.log` (**Reveal Log in Finder** in Settings) records
every DDC transaction (display, VCP code, read or write, result and how long
it took), every sleep, wake and display change BrightSync saw, and every light
reading with the brightness it asked for. That is the
only way to tell a quietly ignored DDC write from one that took, and it shows
what was last sent if a display ever hangs. Past 1 MB the file moves to
`BrightSync.log.1`.

```
2026-10-21T21:14:03Z  event: displays woke
2026-10-21T21:15:03Z  displays settled: STUDIO DISPLAY, ACME 27
2026-10-21T21:15:03Z  ddc read  STUDIO DISPLAY 0x10 → 61/100 (98 ms)
2026-10-21T21:15:03Z  ddc read  ACME 27 0x10 → 40/100 (97 ms)
2026-10-21T21:15:03Z  ddc write ACME 27 0x10 = 61 → sent (23 ms)
2026-10-21T21:40:12Z  hue: Desk sensor 64 lux
2026-10-21T21:40:12Z  ambient: 64 lux → 74%
2026-10-21T21:40:12Z  ddc write ACME 27 0x10 = 74 → sent (24 ms)
```

## Tests

```sh
./test.sh
```

The tests drive the sync engine against a fake set of displays and a fake
clock, and check the exact DDC transactions sent: none before the launch quiet
period ends, none while displays sleep, one read per round in a steady state,
backing off after failures, following a sensor target, and so on. Others
cover the brightness curve, the event stream parser and parsing the Hue
bridge's replies.

## Credits

- Display matching over the IORegistry comes from
  [m1ddc](https://github.com/waydabber/m1ddc) by waydabber (MIT, see
  `LICENSE-m1ddc`); `Sources/DDCKit/ioregistry.m` is kept verbatim from it.
- The DDC reply framing — reading the reply at I2C offset 0 as 11 bytes and
  validating header and checksum — follows
  [MonitorControl](https://github.com/MonitorControl/MonitorControl)'s
  `Arm64DDC` (MIT), which is what works on displays whose replies are
  otherwise unreadable.

MIT licensed.
