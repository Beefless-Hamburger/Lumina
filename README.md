# Lumina

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-orange.svg)](#building-from-source)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Lumina is a macOS menu bar utility for external displays that ignore normal macOS sleep and wake behavior.

It targets a specific hardware annoyance: the Mac locks or sleeps, but an external display keeps behaving as if it is still receiving a signal. The monitor may stay awake, flicker on slightly, keep scanning for input, or refuse to wake cleanly afterward. Lumina uses the BetterDisplay CLI to run a display power-cycle sequence at the moments that matter: lock, unlock, sleep, and wake.

## Purpose

Lumina is designed for setups where macOS display sleep is not enough. Some external displays, adapters, docks, hubs, or cables can leave a phantom or lingering signal that prevents the monitor from fully powering down. Lumina automates the recovery sequence that would otherwise require opening BetterDisplay, toggling display state manually, pressing monitor buttons, or unplugging cables.

When the Mac locks or sleeps, Lumina can disconnect the selected display and send a DDC power-off command. When the Mac wakes or unlocks, it reconnects the display, sends a DDC power-on command, reinitializes the display, and restores backlight state.

Lumina is not a general display manager. It is a focused automation layer around BetterDisplay for one job: make selected external displays power down and come back cleanly with the Mac.

## Built For

- External displays that ignore normal macOS sleep/wake behavior.
- Monitors that stay lit, show a black-but-awake screen, flicker on slightly, or keep scanning for input after macOS sleeps.
- USB-C, HDMI, dock, hub, or adapter setups that leave a phantom signal active.
- Displays that need a stronger wake sequence than macOS normally sends.
- Menu bar workflows where display recovery should happen automatically in the background.

## Features

- **Lock and Sleep Shutdown**: Sends disconnect and DDC power-off commands when the Mac locks or sleeps.
- **Wake Recovery Sequence**: Reconnects the display, sends DDC power-on, reinitializes the display, and restores backlight state.
- **Menu Bar Controls**: Runs without a Dock icon and exposes manual power, refresh, target-selection, and quit actions from the menu bar.
- **Target Selection**: Supports one selected display or all detected displays.
- **Independent Automation Toggles**: Enables auto-off on lock/sleep and auto-on on unlock/wake separately.
- **Launch at Login**: Uses macOS ServiceManagement to register or unregister the app as a login item.
- **Persistent Preferences**: Stores display target and automation settings in `UserDefaults`.

## Requirements

- macOS 13.0 or later.
- Apple Silicon for the provided `build.sh` target.
- [BetterDisplay](https://github.com/waydabber/BetterDisplay) installed at `/Applications/BetterDisplay.app`.
- A display path supported by BetterDisplay's CLI and DDC controls.

## Building from Source

Clone the repository and run:

```bash
bash build.sh
```

The app bundle is created at:

```text
Build/Lumina.app
```

The build script compiles the Swift sources directly with `swiftc`, creates the app bundle and `Info.plist`, copies the app icon, strips cloud-sync extended attributes that can break signing, and ad-hoc signs the bundle.

## Testing

Run the backend tests:

```bash
bash test_backend.sh
```

Run the logic tests:

```bash
bash test_logic.sh
```

## How It Works

Lumina observes macOS lock, unlock, sleep, and wake events. The app treats those events as triggers for a serialized BetterDisplay command sequence.

On lock or sleep:

```text
connected=off
ddc powerMode=4
```

On unlock or wake:

```text
connected=on
ddc powerMode=1
reinitialize
hardwareBacklight=on
ddc powerMode=1
```

The wake sequence is intentionally staged. Some displays need the reconnect, power-on, reinitialize, and backlight recovery commands to arrive separately before they settle into a usable state.

## Architecture

- `DisplayMonitor.swift`: menu bar UI, settings, lifecycle observers, target resolution, and automation triggers.
- `BetterDisplayService.swift`: serialized display power-on and power-off sequences.
- `SystemBetterDisplayTransport.swift`: BetterDisplay launch detection and direct `Process` execution.
- `BetterDisplayOutputParser.swift`: parsing and filtering BetterDisplay display identifiers.
- `DisplayLogic.swift`: pure target/status helpers used by tests.

The app invokes BetterDisplay with `Process.arguments` rather than shell interpolation. Display names remain single argument values, which avoids shell parsing behavior.

## Privacy And Local Data

Lumina is local-only. It does not include networking code, analytics, telemetry, or remote services.

The app stores local preferences with `UserDefaults`, including the selected display name and automation toggles. Runtime logs mark display labels and BetterDisplay diagnostics as private.

## Limitations

- Lumina depends on BetterDisplay and does not replace it.
- DDC behavior varies by monitor, adapter, dock, and cable.
- Some displays may not support every command in the wake or shutdown sequence.
- The app is currently distributed as source and a local build script, not as a notarized release package.

## License

MIT. See [LICENSE](LICENSE).
