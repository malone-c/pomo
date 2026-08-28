# pomo

Ambient pomodoro overlay for macOS. A full-screen, always-on-top, fully click-through window shows faint timer digits and tints the screen edges while a pomodoro is running (red for work, green for break). Cycles 25/5 until paused.

## Build and run

```sh
./build.sh
open Pomo.app
```

Requires the Xcode command line tools (`swiftc`).

## Controls

- **Menu bar 🍅** — Start/Pause, Reset, Quit.
- **Hover** the digits to make them readable; move away and they fade back out.
- **Cmd-click the digits**: hold and drag to reposition them (position is remembered); a quick tap toggles start/pause.
- **Side mouse buttons** (back/forward) work the same way, if your mouse delivers them to macOS as real button presses.
- Plain clicks never touch the overlay — they always pass through to whatever is underneath.

## Notes

- The overlay window is fully click-through; presses are detected by polling button state, not by receiving events. The app under the cursor therefore also sees every press, including cmd-clicks on the digits.
- Mouse remapping software (Logi Options+, OpenLogi, ...) often delivers side buttons as instant synthetic clicks or not at all; cmd-click always works.
