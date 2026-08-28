# pomo

Ambient pomodoro overlay for macOS. A full-screen, always-on-top, fully click-through window shows faint timer digits and tints the screen edges while a pomodoro is running (red for work, green for break). Alternates work and break intervals (default 25/5 minutes, adjustable in the menu); "Auto-start next interval" controls whether the next one begins on its own or waits for Start.

## Build and run

```sh
./build.sh
open Pomo.app
```

Requires the Xcode command line tools (`swiftc`).

## Controls

- **Menu bar 🍅** — Start/Pause, Reset, Quit, and appearance settings: Border (opacity, width, colour) and Timer (size, opacity, font). Settings persist; border tweaks preview the tint for a moment when the timer is idle.
- **Hover** the digits to make them readable; move away and they fade back out.
- **Cmd-click the digits**: hold and drag to reposition them (position is remembered); a quick tap toggles start/pause.
- **Side mouse buttons** (back/forward) work the same way.

## Notes

- The overlay window is click-through, except while cmd is held over the digits — those clicks are caught by the overlay and never reach the app behind. Presses are detected by polling button state, so side-button presses still pass through.
- Mouse remapping software (Logi Options+, OpenLogi, ...) often delivers side buttons as instant synthetic clicks or not at all; cmd-click always works.
