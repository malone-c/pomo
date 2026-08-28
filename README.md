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
- **Side mouse button** (back/forward, e.g. Mouse 5 on a Logitech M650): hold on the digits and drag to reposition them (position is remembered); a quick tap on the digits toggles start/pause.
- Normal clicks never touch the overlay — they always pass through to whatever is underneath.

## Notes

- The side-button events are observed, not consumed, so the app under the cursor also sees them (a browser may interpret Mouse 5 as "forward").
- If Logi Options+ remaps the side buttons to gestures or keystrokes, set them back to default back/forward for dragging to work.
