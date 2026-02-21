# sound-control-mac

Menu bar macOS app for per-app audio control with persistent app profiles.

## Implemented

- SwiftUI menu bar UI (`MenuBarExtra`) with:
  - `DEVICE` section:
    - Output/Input tabs
    - Per-device row controls (default-device radio, icon, name, slider, typed percentage input)
    - Per-device hardware volume control when supported, with DDC fallback for external display audio outputs
    - Per-device 5-band EQ for output devices (per-app EQ overrides per-device EQ)
  - `APPS` section:
    - Per-app volume slider
    - Per-app mute toggle
    - Inline editable per-app percentage
    - Expandable per-app 5-band EQ (`80Hz`, `250Hz`, `1k`, `4k`, `12k`)
- Global output/input default device selection through CoreAudio.
- Profile persistence per bundle identifier with optional "remember" toggle.
- Settings UI for enabling/disabling remembered app profiles.
- Runtime-only profile mode when remember is disabled.
- Core Audio tap routing service (`CoreAudioTapRoutingService`) that:
  - Resolves PID to CoreAudio process objects
  - Creates per-app process taps (`AudioHardwareCreateProcessTap`)
  - Creates private aggregate devices and IOProc callbacks
  - Applies per-app mute/volume and 5-band EQ DSP in the callback path
  - Hard-clamps output samples to `[-1, 1]` to avoid clipping overflow
- Fallback `StubRoutingService` when taps are unavailable.

## Current Limitations

- Core Audio tap flow requires macOS 14.2+.
- Per-device hardware volume may be unavailable for some devices/scopes (shown as disabled with `N/A`).
- DDC control depends on the display exposing speaker volume controls over DDC/CI.
- Per-app input source routing is not implemented.
- Tap-based routing reliability still depends on process/device behavior in HAL; additional hardening is still needed for production.

## Build

```bash
swift build
```

## Test

```bash
swift test
```

## Xcode App Project

- Open `SoundControlMac.xcodeproj` in Xcode.
- Scheme: `SoundControlMac`
- Target: `SoundControlMac`
- Deployment target: macOS 14.2
- Bundle ID: `com.minkyu.soundcontrolmac`

CLI validation command:

```bash
DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer xcodebuild -project SoundControlMac.xcodeproj -scheme SoundControlMac -configuration Debug -sdk macosx build
```

## Project Structure

- `Sources/SoundControlMac/App`: app entry and app delegate
- `Sources/SoundControlMac/Models`: domain models
- `Sources/SoundControlMac/Services`: CoreAudio device manager, app monitor, routing services
- `Sources/SoundControlMac/Stores`: persistence and app-level state store
- `Sources/SoundControlMac/Views`: menu bar and settings SwiftUI views
- `Tests/SoundControlMacTests`: persistence tests
