# Dynamic Cursors for macOS

> Tested on macOS 27.0 (26A5378j), Apple M1, with SIP enabled.

Standalone native proof of concept for the effects in
[egon-r/hypr-dynamic-cursors](https://github.com/egon-r/hypr-dynamic-cursors).
Targets this release, not future macOS compatibility. No dependencies beyond
AppKit, Metal, and the Xcode Command Line Tools; no SIP changes, app injection,
screen capture, launch agent, or installation into system directories.

## Run

The built app is `build/Dynamic Cursors.app`:

```sh
open "$HOME/Projects/dynamic-cursors-macos/build/Dynamic Cursors.app"
```

A **DC** item appears in the menu bar; there is no Dock icon. Effects start
enabled. Open its menu to pause/configure/quit. Opening the menu temporarily
restores the native pointer; closing it resumes the selected effect.

The cursor is **1.8× the native size**, scaling around the exact click hotspot.
Dynamics use the heavier profile from the Linux fork: **Tilt**, **inertia 2**,
**blur strength 2 refresh intervals**, **8 samples**, shake enlargement off.
The menu selects tilt, rotate, stretch, or no deformation; inertia 0/1/2/4;
blur off/1/2/4; and optional shake enlargement. Blur is independent of the mode.
Settings are deliberately session-only.

**Quit Dynamic Cursors** restores the native cursor. For terminal shutdown:

```sh
killall -TERM DynamicCursors
```

## Build and smoke

```sh
make app
make smoke
```

`make app` release-builds the Swift executable and creates an ad-hoc-signed app
bundle. `make smoke` briefly runs the real overlays, exercises the menu actions
for every mode and enabled/disabled transitions, exports actual Metal-pipeline
renders to `/tmp/dynamic-cursors-smoke/`, checks shrinking blur after stopping,
checks exact pointer position, and verifies replacement/restoration without
changing the foreground application. It exits afterward. Quit any running copy
before smoke-testing or rebuilding its bundle.

Local verification also exercised SIGTERM restoration. The Command Line Tools
linker emitted warnings about two nonexistent Developer search paths; the app
built and ran successfully without modifying the toolchain.

## Implementation

- Poll global pointer position at display refresh cadence; sample the current
  system cursor image/hotspot at 30 Hz. Upload a new Metal texture only when
  the actual image changes.
- Apply the fork's closed-form angular spring, dragged-stick rotation,
  directional stretch/squash, optional shake enlargement, and time-windowed
  motion history. Keep the click position/hotspot exact.
- Average the transformed sprite along its displacement in a Metal fragment
  shader, with premultiplied alpha. Exposure is strength / refresh rate, capped
  at 250 ms. Stationary history shrinks the smear back to a sharp sprite.
- Render through transparent, click-through overlays. Reuse the existing
  frame when idle rather than submitting identical GPU work.
- Enable the private, process-local `SetsCursorInBackground` connection
  property, then own one balanced CoreGraphics hide/show count. Restore on
  pause, quit, SIGINT/SIGTERM, and session sleep/inactivation. Do not hide the
  native cursor unless the replacement frame was submitted successfully.
  Reconcile actual native visibility even on idle frames; if it reappears,
  balance the previous hide before reacquiring it instead of stacking hides.

Physics and blur are adapted from the MIT-licensed Linux fork; see `LICENSE`.
The Hyprland hooks, renderer integration, and Lua configuration are not used.

## Limits

- Uses private `CGSMainConnectionID` / `CGSSetConnectionProperty` and deprecated
  `NSCursor.currentSystem`. These work on the tested release and can break in
  an OS update. This is not an App Store/public-API implementation.
- A foreground application's independent intent to hide its cursor cannot be
  distinguished reliably while this app owns its hide count. The replacement
  can remain visible in games, pointer-lock apps, or apps that hide the pointer
  while typing. Disable effects there using the menu.
- Tracks image/hotspot changes, not Hyprland's semantic cursor shape names;
  Lua per-shape rules and hyprcursor themes are not imported.
- Polling/software overlays do not have hardware-cursor latency. This is not
  guaranteed to match the compositor-integrated Linux version's responsiveness.
- A single Retina display was exercised. Full-screen Spaces, external display
  hotplug, HDR/color-management fidelity, and arbitrary custom/animated cursors
  have not been exhaustively validated. No screen-recording permission was
  granted; visual inspection used exports from the same Metal pipeline rather
  than a desktop screen capture.
