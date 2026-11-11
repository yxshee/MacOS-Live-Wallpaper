# Writing and porting shader scenes

A shader scene is a folder. Put it in `Scenes/` and rebuild (to ship it with the app), or in `~/Library/Application Support/Live Wallpaper/Scenes/` (for yourself), and it appears in the menu the next time the app starts. If it does not appear, `--list-scenes` says why.

```
Scenes/my-scene/
  scene.json    what it is, who made it, its licence, how hard to drive it
  LICENSE       the scene's own licence text, its credit, and what you changed
  main.metal    the shader
  noise.png     optional: up to two images the shader can sample
```

The folder name is the scene's id: letters, digits, `-` and `_` only. `horizon`, `nebula` and `video` are taken, and a folder of your own cannot replace a bundled scene of the same name.

## scene.json

```json
{
  "title": "Star Nest",
  "author": "Pablo Roman Andrioli (Kali)",
  "source": "https://www.shadertoy.com/view/XlfGRj",
  "licence": "MIT",
  "style": "nature",
  "maxFPS": 15,
  "scale": 0.5,
  "channels": ["noise.png"]
}
```

| Field | Meaning |
|---|---|
| `title`, `author`, `source` | Shown in the menu. `source` must be an `https://` link to the original. |
| `licence` | An SPDX identifier: `MIT`, `CC0-1.0`, `CC-BY-4.0`, `CC-BY-NC-SA-3.0` and so on. Anything containing `-NC` is marked non-commercial in the menu and left out of `--permissive-only` builds. |
| `style` | `nature`, `stylised`, `abstract`, `cosy` or `scifi`: the submenu it appears in. |
| `maxFPS` | The most frames a second it is ever drawn at (1 to 60, default 20). The app lowers this itself on battery, when another app is in front, and in Low Power Mode: a scene set to 30 is drawn at 30 only while you are looking at the desktop on mains power, and at 15 behind another app. |
| `scale` | Pixels drawn per point of screen (0.125 to 2, default 0.5). 0.5 means half the points each way, a sixteenth of a Retina display's pixels. Soft scenes look fine at 0.35 to 0.5; scenes with thin lines or small stars want 1. |
| `channels` | Up to two image files in the folder, bound as `iChannel0` and `iChannel1`. Each may be at most 4096 pixels a side. A grey-scale image reads as grey in `.rgb`, as it would in GLSL. |

## The shader

`main.metal` is Metal Shading Language written the way a Shadertoy shader is. It ends in:

```metal
void mainImage(thread vec4& fragColor, vec2 fragCoord)
```

`fragCoord` is in pixels with the origin at the bottom left, as in GLSL. Write a display-ready colour to `fragColor`.

The app wraps your whole file in a struct before compiling it. That is why these all work, though plain Metal would refuse them:

- Every function can use the inputs below without having them passed in.
- Functions may be called before they are defined.
- Variables declared outside any function ("globals") may be assigned to.

### Inputs

| Name | Type | Meaning |
|---|---|---|
| `iResolution` | `vec3` | Size of what you are drawing into, in pixels (`.z` is 1). |
| `iTime` | `float` | Seconds of animation. It stops while the wallpaper is hidden. |
| `iTimeDelta` | `float` | Seconds since the previous frame. |
| `iFrame` | `int` | Frame number. |
| `iMouse` | `vec4` | Always zero in a wallpaper; there for compatibility. |
| `iDate` | `vec4` | Year, month (0 to 11), day, seconds since local midnight. |
| `iChannel0`, `iChannel1` | `texture2d<float>` | Your images, or 1×1 black if you gave none. |
| `iChannelResolution[2]` | `vec3` | Their sizes. |
| `lwSunElevation` | `float` | The real sun's height in degrees at the user's place, negative at night. |
| `lwSunAzimuth` | `float` | Its compass direction in degrees. |
| `lwDaylight` | `float` | 0 at night, 1 by day, easing through twilight. |
| `lwMoon` | `float` | How much of the moon is lit tonight, 0 to 1. |

The last four let a scene follow the actual day. They are optional.

### What the prelude gives you

GLSL type names (`vec2`, `vec3`, `vec4`, `ivec2`…, `mat2`, `mat3`, `mat4`), GLSL-style `mod`, two-argument `atan`, a `smoothstep` that also works with its edges given high-then-low (Metal's own is undefined that way round), `inversesqrt`, `dFdx`/`dFdy`, `texture(iChannel0, uv)`, `textureLod`, `texelFetch`, `textureSize`, and the samplers `lwRepeat`, `lwClamp`, `lwNearest`. See `Resources/ScenePrelude.metal`.

## Porting from GLSL

Most of a Shadertoy shader compiles as it is. What needs changing by hand:

| GLSL | Metal |
|---|---|
| `void mainImage(out vec4 c, in vec2 p)` | `void mainImage(thread vec4& c, vec2 p)` |
| `out T x`, `inout T x` parameters | `thread T& x` |
| `v.xz *= m;` (matrix on a swizzle) | `v.xz = v.xz * m;` |
| `const vec3 a[3] = vec3[3](x, y, z);` | `const vec3 a[3] = { x, y, z };` |
| `vec3[3](x, y, z)` as an expression | a named local array |
| `mat3(m4)` | build it from the columns: `mat3(m4[0].xyz, m4[1].xyz, m4[2].xyz)` |
| `lessThan(a, b)` on types the prelude lacks | `a < b` |
| `mix(a, b, boolVector)` | `select(a, b, boolVector)` |
| `discard;` | `discard_fragment();` |
| `precision mediump float;` | delete the line |
| `a ^^ b`, `%` on floats | rewrite |
| a function overloaded only by return type | rename one |
| names `half`, `char`, `kernel`, `vertex`, `fragment`, `constant`, `device`, `thread`, `sampler`, `uniform`, `template`, `class`, `this`, `new` | rename (they are reserved in Metal) |

Things that are the same and need no change: `in` parameters (the word is ignored), `mat2(a, b, c, d)` from four numbers, `m * v` and `v * m` (both languages are column-major), `fract`, `mix`, `step`, `smoothstep`, `clamp`, `length`, `dot`, `cross`, `normalize`, `reflect`, `pow`, `exp`, swizzles.

Two habits of GLSL that bite:

- **Uninitialised variables.** GLSL drivers usually zero them; Metal does not. Initialise every local.
- **Texture lookups in loops.** The prelude's `texture()` samples mip level 0 on purpose, because automatic mip selection is undefined inside loops and branches. Use `textureLod` if you want a blurrier level.

Shadertoy's built-in noise textures are not provided. If a shader needs one, generate an equivalent image and ship it in the folder (say so in `LICENSE`), or replace the lookup with a hash.

Shaders with several buffers (Buffer A feeding the image), audio, webcam or keyboard input are not supported.

## Check it without touching your desktop

```bash
APP=build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper

$APP --render out.png --scene-dir Scenes/my-scene --size 2056x1329 --scale 1 --t 30
$APP --bench 120 --scene-dir Scenes/my-scene        # GPU milliseconds per frame at 4112x2658
$APP --check-scenes                                  # every bundled scene: compiles, draws, costs
```

A compile error is printed with line numbers in your `main.metal`.

## How much it may cost

This app's promise is that it costs almost nothing, and an imported shader is where that promise is easiest to break. The rule for bundled scenes:

> milliseconds per frame from `--bench` × `maxFPS` must be 20 or less.

That is 2% of one GPU-second per second on an M-series MacBook Pro at full Retina size. If a scene is over, lower `scale` first (soft scenes lose nothing down to about 0.35), then `maxFPS` (slow scenes look the same at 10 to 15). Do not change the shader's own maths or step counts to make it cheaper unless the result still looks like the original.

At run time the app also watches each scene's real GPU time and lowers its resolution, then its frame rate, if it runs over.

## Licences

- Only bring in a scene if its author's licence lets it be redistributed, and quote that licence in `LICENSE` with a link to where it is stated. A licence on a host project's code does not cover the shaders it bundles; find the shader's own.
- Keep the author's header comment at the top of `main.metal`, and add a line saying what you changed.
- On Shadertoy, a shader whose author states no licence falls under the site's default (CC BY-NC-SA 3.0). Do not rely on that default for a bundled scene; import only shaders whose own text states a licence.
- Non-commercial scenes are welcome. They are marked in the menu, listed in `Scenes/NONCOMMERCIAL.md`, and left out of `--permissive-only` builds.
