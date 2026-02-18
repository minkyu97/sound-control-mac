# sound-control-mac

Menu bar macOS app for per-app audio control with persistent app profiles.

## Implemented

- SwiftUI menu bar UI (`MenuBarExtra`) with:
  - Running app list
  - Per-app volume slider
  - Per-app mute toggle
  - Per-app preferred output device selector
- Global output/input device selection through CoreAudio.
- Profile persistence per bundle identifier with optional "remember" toggle.
- Settings UI for enabling/disabling remembered app profiles.
- Runtime-only profile mode when remember is disabled.
- Core Audio tap routing service (`CoreAudioTapRoutingService`) that:
  - Resolves PID to CoreAudio process objects
  - Creates per-app process taps (`AudioHardwareCreateProcessTap`)
  - Creates private aggregate devices and IOProc callbacks
  - Applies per-app mute/volume gain in the callback path
  - Routes each tapped app stream to selected output device UID
- Fallback `StubRoutingService` when taps are unavailable.

## Current Limitations

- Core Audio tap flow requires macOS 14.2+.
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
