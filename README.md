<div align="center">

# Lumina

**Reliable sleep and wake automation for stubborn external displays on macOS.**

[![CI](https://github.com/Beefless-Hamburger/Lumina/actions/workflows/ci.yml/badge.svg)](https://github.com/Beefless-Hamburger/Lumina/actions/workflows/ci.yml)
[![Latest Release](https://img.shields.io/github/v/release/Beefless-Hamburger/Lumina?display_name=tag)](https://github.com/Beefless-Hamburger/Lumina/releases/latest)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](#development)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Lumina is a focused macOS menu bar utility that uses the BetterDisplay CLI to power selected external displays down when your Mac locks or sleeps, then bring them back through a staged recovery sequence when it unlocks or wakes.

[Download](#download-and-install) · [Usage](#usage) · [Troubleshooting](#troubleshooting) · [Development](#development)

</div>

## Why Lumina Exists

Some external monitors never fully settle when macOS sleeps. They may remain backlit, repeatedly scan for an input, briefly flicker awake, or fail to reconnect cleanly afterward. Docks, adapters, cables, and imperfect DDC implementations can make the behavior even less predictable.

Lumina automates the sequence that would otherwise require opening BetterDisplay, toggling connection state, pressing monitor controls, or reconnecting hardware.

It is intentionally narrow in scope. Lumina is not a general display manager and does not replace BetterDisplay. It provides reliable lifecycle automation for displays that need a stronger shutdown and recovery sequence than macOS sends on its own.

## Features

- **Automatic shutdown:** Disconnects selected displays and sends a DDC power-off command when macOS locks or sleeps.
- **Staged wake recovery:** Reconnects displays, powers them on through DDC, reinitializes them, restores hardware backlight state, and sends a final power-on command.
- **Independent automation controls:** Enable or disable shutdown and wake automation separately.
- **Flexible targeting:** Control one selected display or every display reported by BetterDisplay.
- **Manual recovery controls:** Force power on or off directly from the menu bar.
- **Automatic BetterDisplay launch:** Starts BetterDisplay in the background when a command requires it.
- **Launch at login:** Registers Lumina as a macOS login item through ServiceManagement.
- **Persistent settings:** Remembers display targets and automation preferences between launches.
- **Local operation:** Contains no telemetry, analytics, networking, or remote service integration.

## Requirements

- macOS 13.0 or later.
- An Apple Silicon or Intel Mac.
- [BetterDisplay](https://github.com/waydabber/BetterDisplay) installed at `/Applications/BetterDisplay.app`.
- A monitor connection that BetterDisplay can identify and control. DDC support depends on the display, dock, adapter, and cable path.

Building from source additionally requires Xcode Command Line Tools or another macOS Swift toolchain that provides `swiftc`.

## Download and Install

1. Open the [latest Lumina release](https://github.com/Beefless-Hamburger/Lumina/releases/latest).
2. Download `Lumina-<version>.dmg`.
3. Open the DMG and drag **Lumina.app** into the **Applications** shortcut.
4. Confirm that BetterDisplay is installed in `/Applications`.
5. Open Lumina from Applications.

Release DMGs contain a universal application that runs natively on Apple Silicon and Intel Macs.

### First-launch security prompt

Lumina is currently ad-hoc signed rather than Apple-notarized. macOS may block the first launch because it cannot verify a registered developer.

Control-click **Lumina.app**, choose **Open**, then confirm. You can also approve the app under **System Settings → Privacy & Security** after the first blocked launch.

Each release includes a `.sha256` checksum file for verifying the DMG download.

## Initial Setup

1. Open the Lumina menu from the moon-and-stars icon in the macOS menu bar.
2. Choose **Select Specific Display**, then select the monitor you want Lumina to manage.
3. Alternatively, enable **Target All Displays**.
4. Leave **Auto-off on Lock/Sleep** and **Auto-on on Unlock/Wake** enabled.
5. Use **Force Power Off** and **Force Power On** once to confirm that your display path supports the sequence.
6. Enable **Launch at Login** after confirming the configuration works.

Lumina runs as a menu bar utility and does not create a Dock icon.

## Usage

| Control | Purpose |
| --- | --- |
| **Force Power Off** | Immediately runs the shutdown sequence for the current target. |
| **Force Power On** | Immediately runs the staged recovery sequence for the current target. |
| **Target All Displays** | Applies commands to every supported display found by BetterDisplay. |
| **Auto-off on Lock/Sleep** | Runs the shutdown sequence when the Mac locks or enters sleep. |
| **Auto-on on Unlock/Wake** | Runs the recovery sequence after the Mac is both awake and unlocked. |
| **Launch at Login** | Registers or removes Lumina as a macOS login item. |
| **Select Specific Display** | Selects one BetterDisplay display identifier as the target. |
| **Refresh Displays** | Reloads the display list from BetterDisplay. |

Lumina tracks lock and sleep state independently. A wake notification will not power a display on while the Mac remains locked, and an unlock notification will not override an outstanding sleep state.

## Power Sequences

### Lock or sleep

For each selected display, Lumina runs:

```text
connected=off
ddc powerMode=4
```

### Unlock or wake

For each display that reconnects successfully, Lumina runs:

```text
connected=on
ddc powerMode=1
wait 2 seconds
reinitialize
wait 2 seconds
hardwareBacklight=on
ddc powerMode=1
```

The delays are intentional. Some monitors need time to re-establish their connection before accepting reinitialization and backlight commands.

## Reliability Design

Display lifecycle notifications can arrive more than once, overlap, or occur out of order. BetterDisplay commands can also stall or fail independently for different displays. Lumina is designed around those conditions:

- Lock and sleep are maintained as separate state instead of one shared flag.
- Stale power operations are cancelled when lifecycle state or selected targets change.
- BetterDisplay commands are serialized while cancellation can still reach the active process.
- Child processes have bounded output capture, timeouts, and termination escalation.
- A failure on one display does not automatically prevent unaffected displays from continuing.
- The wake sequence skips later stages for a display that failed its initial reconnect.
- Display identifiers are passed as direct process arguments rather than interpolated into shell commands.

## Troubleshooting

### No displays appear

- Confirm BetterDisplay is installed in `/Applications`.
- Open BetterDisplay once and verify that it can see the monitor.
- Choose **Refresh Displays** from Lumina.
- Confirm the display is not represented only as a BetterDisplay group or another non-display record.

### The monitor does not power off

- Test **Force Power Off** before relying on automatic lock or sleep behavior.
- Verify that BetterDisplay can disconnect the display manually.
- Check whether DDC commands work through the current cable, adapter, dock, or hub.
- Try selecting the display individually instead of using **Target All Displays**.

### The monitor does not wake cleanly

- Run **Force Power On** and allow the entire staged sequence to complete.
- Confirm that BetterDisplay can reconnect and reinitialize the display manually.
- Test a direct connection if the display is currently routed through a dock or adapter.
- Some displays ignore hardware backlight or DDC power commands even when connection toggling works.

### Launch at Login does not remain enabled

Open **System Settings → General → Login Items & Extensions** and confirm that Lumina is allowed to run at login. Lumina should be installed in Applications before registering it as a login item.

## Development

Lumina is built directly with `swiftc`; it does not require an Xcode project.

### Build the app

```bash
git clone https://github.com/Beefless-Hamburger/Lumina.git
cd Lumina
bash build.sh
```

The optimized, ad-hoc-signed application bundle is created at `Build/Lumina.app`.

The build script compiles with complete Swift concurrency diagnostics, stages the application before replacing an existing build, removes problematic extended attributes, and verifies the final signature.

To build for the current machine architecture:

```bash
BUILD_TARGET="$(uname -m)-apple-macosx13.0" bash build.sh
```

Version and output values can also be supplied explicitly:

```bash
APP_VERSION="1.0.1" BUILD_DIR="Build" bash build.sh
```

### Build a universal DMG

```bash
VERSION="1.0.1" bash package_dmg.sh
```

This compiles Apple Silicon and Intel variants, combines them into a universal binary, verifies the app signature, creates a drag-and-drop DMG, and writes a SHA-256 checksum under `dist/`.

### Test

```bash
bash test_logic.sh
bash test_backend.sh
```

The logic suite covers lifecycle transitions, target resolution, and status behavior. The backend suite covers process execution, cancellation, timeouts, output limits, BetterDisplay launch behavior, power sequencing, partial failures, stale-operation suppression, parser behavior, and heartbeat lifecycle management.

GitHub Actions validates the shell scripts, runs both test suites, creates an optimized app build, and verifies the final code signature on every pull request and push to `main`.

Releases are produced by `.github/workflows/release.yml`. Updating `.github/release-version` or manually running the workflow builds and publishes a universal DMG under GitHub Releases.

### Project Structure

| File | Responsibility |
| --- | --- |
| `DisplayMonitor.swift` | Menu bar interface, preferences, lifecycle observers, target resolution, and automation coordination. |
| `DisplayLogic.swift` | Pure lifecycle, target, and status logic used by the app and tests. |
| `BetterDisplayService.swift` | Serialized power-off and staged power-on sequences. |
| `SystemBetterDisplayTransport.swift` | BetterDisplay discovery, background launch, command dispatch, and result mapping. |
| `AsyncProcessRunner.swift` | Asynchronous process execution with cancellation, timeout, and bounded output handling. |
| `BetterDisplayOutputParser.swift` | Defensive parsing and filtering of BetterDisplay display identifiers. |
| `ShutdownHeartbeatController.swift` | Repeats shutdown enforcement while the system remains inactive. |
| `package_dmg.sh` | Builds, signs, verifies, and packages a universal release DMG. |
| `LuminaLogicTests.swift` | Deterministic tests for pure application logic. |
| `LuminaBackendTests.swift` | Deterministic tests for transport, sequencing, parser, process, and heartbeat behavior. |

## Privacy

Lumina operates entirely on the local Mac. It contains no networking code, telemetry, analytics, advertising, or remote service integration.

Preferences are stored locally with `UserDefaults`. Runtime logging uses macOS unified logging and marks display labels and BetterDisplay diagnostics as private where appropriate.

## Limitations

- BetterDisplay is required and must remain installed for Lumina to function.
- DDC support varies significantly across monitors and connection paths.
- Some displays support connection toggling but ignore power, reinitialization, or hardware backlight commands.
- Release builds are ad-hoc signed and are not currently notarized by Apple.
- Real hardware behavior cannot be fully represented by automated tests.

## License

Lumina is available under the [MIT License](LICENSE).

BetterDisplay is a separate project maintained by its own developers. Lumina is not affiliated with or endorsed by BetterDisplay.