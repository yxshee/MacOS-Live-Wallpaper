# Contributing

Thanks for looking. This is a small project and changes of any size are welcome: a bug report, a result from a Mac it has not been tried on, a palette tweak, a new scene.

## Build and test

You need Xcode or the Command Line Tools. Nothing else.

```bash
swift test                    # unit tests: astronomy, location, palette, terrain, layout
./scripts/build-app.sh        # builds ./build/LiveWallpaper.app, touches nothing else
./scripts/build-app.sh --install   # also copies it to ~/Applications and starts it
./scripts/build-app.sh --universal # one binary for Apple Silicon and Intel (needs full Xcode)
```

On recent SDKs `--universal` prints a warning that x86_64 is deprecated; the build still succeeds.

`swift build` alone gives you the bare executable, but the app needs to run from the `.app` bundle: that is where it finds `Shaders.metal`.

## See your change without touching your desktop

The binary can draw frames off screen and exit. No window opens and your wallpaper is left alone.

```bash
APP=build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper

$APP --render dusk.png --sky dusk
$APP --render moon.png --date "2026-11-24 21:30" --cloud 0.2
$APP --render south.png --hour 7 --lat -33.87 --lon 151.21
$APP --render wide.png --size 5120x1440 --scale 1
$APP --bench 400 --hour 1.5 --aurora 1      # GPU milliseconds per frame
$APP --help                                 # every option
```

`--date` and `--hour` are in your Mac's own time zone. Frames use the default landscape and your time zone's city, whatever the installed app has saved; pass `--seed`, `--lat` and `--lon` to change them. A flag the binary does not know is an error: it never falls through to starting the wallpaper.

Please attach a rendered frame to any pull request that changes how something looks.

Two environment variables help when testing the real app. Start the binary from a terminal with them set:

- `LW_STATS=1` prints the frame rate asked for and delivered, and CPU and GPU time per frame.
- `LW_ALWAYS_PLAY=1` keeps drawing while the desktop is covered, so you can capture the window.

## How the code is laid out

| File | What is in it |
|---|---|
| `Astro.swift` | Where the sun and moon are for a date and place. Pure arithmetic. |
| `Location.swift` | A rough location from the time zone table, without location permission. |
| `Palette.swift` | Sky and ridge colours, keyed by how high the sun is. |
| `Terrain.swift` | The mountain ridges: six height profiles built once from a seed. |
| `SceneModel.swift` | Turns a date and place into the numbers the shaders are given each frame. |
| `Uniforms.swift` | Those numbers as a struct. It must match `Shaders.metal` field for field. |
| `Renderer.swift` | Metal set-up and the three passes. |
| `SceneView.swift` | The two layers on screen, the display link and the frame-rate policy. |
| `App.swift` | Windows, the menu, settings. |
| `Headless.swift` | `--render` and `--bench`. |
| `Conditions.swift` | Battery, Low Power Mode, heat, and whether Finder (the desktop) is in front. |
| `NoiseBake.swift` | The noise texture baked at launch. |
| `Math.swift` | Small vector and easing helpers. |
| `main.swift` | Entry point: any `--flag` draws off screen, otherwise the menu-bar app starts. |
| `Resources/Shaders.metal` | All the drawing. |

A frame is three passes: a soft sky at a quarter of the sky's resolution, the sky layer at one pixel per point (the soft sky plus stars, sun and moon), and a Retina ridge layer drawn only when it would look different.

## Things that will catch you out

- **Shaders are compiled when the app starts, not when you build.** A mistake in `Shaders.metal` shows up only at run time. Run `--render` after every shader edit; it prints the compiler's error.
- **Fragment inputs need `[[stage_in]]`.**
- **`Uniforms` is copied into the shader byte for byte.** If you add a field, add it in both places, in the same position. `swift test` checks the total size, not the order.
- **Anything that animates must survive weeks of uptime.** Time reaches the shaders as values wrapped to a period (`wrap(elapsed * speed, 1)`), never as raw seconds. If a shader multiplies a wrapped value, the multiplier must be a whole number or the picture pops at the wrap.
- **Nothing may jump.** Colours and light directions have to change smoothly across noon, midnight, dawn, dusk and the equator. `SceneModelTests.testNothingJumpsThroughTheDay` walks two days at several latitudes and fails on a step.
- **Measure GPU cost under sustained load.** Timing one frame at a time measures how slowly the GPU's clock is idling, not the work. `--bench` queues frames back to back for this reason.
- **Energy is a feature.** A change that draws more often, at higher resolution, or wakes the app when it is hidden needs a reason. Say what it costs in the pull request.

## Pull requests

- Keep each one to a single change.
- Run `swift test` and build the app.
- For visual changes, include before and after frames from `--render`.
- For anything that affects cost, include `--bench` numbers before and after.
- If you tested on hardware or a macOS version not listed in the README, say which.

## Reporting a bug

Please include your Mac model, macOS version, how many displays you have, and what the menu's first line says. A screenshot helps for anything visual.
