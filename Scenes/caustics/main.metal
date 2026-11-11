// Caustics by Andre Hall (Noctura)
// https://github.com/DRAZY/noctura-screensaver/blob/main/src/scenes/Caustics.ts
// MIT License, Copyright (c) 2026 Andre Hall (see LICENSE).
//
// Author's header comment:
//
//   Caustics: the shimmering web of light you see on the floor of a sunlit pool.
//   Built from two slowly-drifting Worley/voronoi-ish distance fields whose ridges
//   are folded into thin bright filaments, layered over a deep water gradient.
//
//   The whole scene lives on one design rule: stay smooth. Every spatial frequency
//   is kept modest, time evolution is slow and continuous, and the filament ridges
//   are anti-aliased with `fwidth` so they soften — never alias or crawl — no matter
//   how sharp the highlight gets. That keeps it buttery on a good GPU with none of
//   the high-frequency shimmer/tearing that naive caustic shaders suffer from.
//
// The 2D simplex noise below was written for that project from the textureless
// simplex noise by Ian McEwan, Ashima Arts, and Stefan Gustavson
// (https://github.com/ashima/webgl-noise, MIT License, Copyright (C) 2011 by
// Ashima Arts); its copyright notice is kept in LICENSE.
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the
// original:
//   - The three.js and TypeScript wrapper (vertex shader, ShaderMaterial,
//     the Speed / Density / Size / Style controls) is removed. The uniforms
//     uSpeed, uScale and uSize are constants at the scene's own defaults
//     (0.4, 5.0, 1.0), and uColorA/B/C are the default "Ocean" palette
//     (#030e2e, #0c5ca3, #6bd2e0).
//   - The palette is written as the linear-light numbers three.js hands the
//     shader for those hex colours (it converts sRGB hex to linear and the
//     shader writes them out unchanged), which is the look of the author's own
//     screenshot of this scene.
//   - main() became mainImage(); vUv is computed from fragCoord and
//     iResolution; gl_FragColor and gl_FragCoord became fragColor and fragCoord.
//   - The `precision` line is dropped, and the swizzled subtraction
//     `x12.xy -= i1` is written out as an assignment.
//   - One addition to worley(). The author's 3x3 cell search is kept, but where
//     its second-nearest distance comes out above 1.0 the ring of cells beyond
//     is searched too. Without it, a few pixels in ten thousand (0.04% in a
//     2056x1329 frame) get a wrong F2 and a filament is cut off along a cell
//     edge in a hard jagged seam. With it the result equals a full 5x5 search,
//     every other pixel is identical to the author's 3x3 result, and it costs
//     about 7% more GPU time.
//   - Nothing else: the maths, constants, step counts and speed are untouched.
//     The animation is already slow (the feature points orbit with a period of
//     31 and 39 seconds), so it was not slowed further.

// The scene's defaults, as the original sets them in createMaterial().
#define uSpeed 0.4          // global time multiplier
#define uScale 5.0          // overall pattern scale
#define uSize  1.0          // caustic cell scale

// "Ocean" palette, #030e2e / #0c5ca3 / #6bd2e0, as linear-light values.
#define uColorA vec3(0.000911, 0.004391, 0.027321)   // deep water (background floor)
#define uColorB vec3(0.003677, 0.107023, 0.366253)   // mid water glow
#define uColorC vec3(0.147027, 0.644480, 0.745404)   // bright caustic light

// ---- 2D simplex noise (Ashima Arts / Stefan Gustavson, MIT) ----
vec3 mod289_3(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec2 mod289_2(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec3 permute3(vec3 x) { return mod289_3(((x * 34.0) + 1.0) * x); }

float snoise(vec2 v) {
  const vec4 C = vec4(0.211324865405187, 0.366025403784439,
                     -0.577350269189626, 0.024390243902439);
  vec2 i  = floor(v + dot(v, C.yy));
  vec2 x0 = v - i + dot(i, C.xx);
  vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
  vec4 x12 = x0.xyxy + C.xxzz;
  x12.xy = x12.xy - i1;
  i = mod289_2(i);
  vec3 p = permute3(permute3(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
  vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
  m = m * m; m = m * m;
  vec3 x = 2.0 * fract(p * C.www) - 1.0;
  vec3 h = abs(x) - 0.5;
  vec3 ox = floor(x + 0.5);
  vec3 a0 = x - ox;
  m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
  vec3 g;
  g.x  = a0.x  * x0.x  + h.x  * x0.y;
  g.yz = a0.yz * x12.xz + h.yz * x12.yw;
  return 130.0 * dot(m, g);
}

// 2D fractional Brownian motion (5 octaves).
float fbm2(vec2 p) {
  float sum = 0.0;
  float amp = 0.5;
  float freq = 1.0;
  for (int i = 0; i < 5; i++) {
    sum += amp * snoise(p * freq);
    freq *= 2.0;
    amp *= 0.5;
  }
  return sum;
}

// Triangular-PDF ordered dither, ~+-1 LSB at 8-bit, to break up banding in the
// smooth dark water gradient.
// ditherHash is hash12 from "Hash without Sine", https://www.shadertoy.com/view/4djSRW,
// Copyright (c)2014 David Hoskins, MIT License (his notice is in the LICENSE file).
// The original file does not name him; the credit is restored here.
float ditherHash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}
vec3 dither(vec2 fragCoord) {
  // Two uniform hashes combined -> triangular distribution (cleaner than uniform).
  vec3 u1 = vec3(ditherHash(fragCoord), ditherHash(fragCoord + 11.7), ditherHash(fragCoord + 23.3));
  vec3 u2 = vec3(ditherHash(fragCoord + 41.1), ditherHash(fragCoord + 57.9), ditherHash(fragCoord + 71.3));
  return (u1 + u2 - 1.0) / 255.0;
}

// ---- Caustics ----

// Smooth 2D value hash -> a stable feature point inside each lattice cell.
// fract/sin is adequate here because we only ever compare *distances*, and the
// distances are smoothed afterward, so any hash artefacts stay sub-visible.
vec2 cellPoint(vec2 cell) {
  float h = dot(cell, vec2(127.1, 311.7));
  vec2 r = vec2(sin(h) * 43758.5453, sin(h + 1.0) * 22578.1459);
  return fract(r);
}

// Worley field returning the nearest TWO distances (F1, F2). Their difference
// (F2 - F1) goes to zero exactly along cell borders - that thin border network
// is the geometry real caustics trace, so we light it rather than filling cells.
// Feature points orbit slowly so the web breathes instead of snapping.
// One lattice cell's feature point, folded into the running nearest two.
void worleyCell(vec2 base, vec2 f, int i, int j, float t, thread float& f1, thread float& f2) {
  vec2 cell = base + vec2(float(i), float(j));
  vec2 fp = cellPoint(cell);
  fp = 0.5 + 0.5 * sin(t + 6.2831853 * fp);
  vec2 diff = vec2(float(i), float(j)) + fp - f;
  float d = length(diff);
  if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }
}

vec2 worley(vec2 p, float t) {
  vec2 base = floor(p);
  vec2 f = fract(p);
  float f1 = 8.0;
  float f2 = 8.0;
  // 3x3 neighbourhood, as the author wrote it. It covers almost every pixel.
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      worleyCell(base, f, i, j, t, f1, f2);
    }
  }
  // Added in the port. A feature point in the ring of cells beyond the 3x3 is at
  // least 1.0 away from this pixel, so the ring can only change F2 where F2 came
  // out above 1.0. Where it does (a few pixels in ten thousand) the 3x3 search
  // alone gives a wrong F2 and the filament is cut off along a cell edge, a hard
  // jagged seam. Searching that ring only when needed removes the seams and
  // costs almost nothing.
  if (f2 > 1.0) {
    for (int j = -2; j <= 2; j++) {
      for (int i = -2; i <= 2; i++) {
        if (abs(i) == 2 || abs(j) == 2) worleyCell(base, f, i, j, t, f1, f2);
      }
    }
  }
  return vec2(f1, f2);
}

// One caustic layer: a thin bright filament riding the cell-border network.
// border = F2 - F1 ~ 0 on edges; we light a narrow band around it and AA the
// band to one screen-space gradient-width (fwidth) so it stays crisp, ~1px, and
// never aliases or crawls. pow() tightens it into a glinting light thread.
float causticLayer(vec2 p, float t, float sharp) {
  vec2 w = worley(p, t);
  float border = w.y - w.x;
  float aa = fwidth(border) + 1e-4;
  float line = 1.0 - smoothstep(0.0, 0.07 + aa, border);
  return pow(clamp(line, 0.0, 1.0), sharp);
}

void mainImage(thread vec4& fragColor, vec2 fragCoord) {
  vec2 vUv = fragCoord / iResolution.xy;
  float aspect = iResolution.x / max(iResolution.y, 1.0);
  vec2 uv = vec2((vUv.x - 0.5) * aspect, vUv.y - 0.5);

  // Slow time. uSpeed defaults low; nothing here moves fast.
  float t = iTime * uSpeed;

  // Base sampling coordinate. uSize controls cell density (Light Size):
  // a larger "size" -> fewer, larger light cells, so we divide the frequency by it.
  vec2 p = uv * uScale / max(uSize, 0.0001);

  // Gentle domain warp from low-frequency fbm so the caustic web drifts and
  // curls like real refracted light, instead of sitting on a static lattice.
  float warpT = t * 0.35;
  vec2 warp = vec2(
    fbm2(p * 0.35 + vec2(warpT, 0.0)),
    fbm2(p * 0.35 + vec2(0.0, warpT) + 17.3)
  );
  vec2 pw = p + warp * 0.6;

  // Two layers at slightly different scales/phases, counter-drifting. Their
  // product (not sum) is what gives caustics their characteristic bright knots
  // where two filament webs cross, with dark calm water between.
  float l1 = causticLayer(pw * 1.00, t * 0.50, 1.3);
  float l2 = causticLayer(pw * 1.37 + 9.1, -t * 0.40, 1.5);
  float caustic = l1 * 0.7 + l2 * 0.7 + l1 * l2 * 2.0;

  // Soft large-scale brightness wash so the light pools and fades across the
  // frame rather than being uniform - reads as sunlight through moving water.
  float wash = 0.5 + 0.5 * fbm2(p * 0.18 + vec2(0.0, t * 0.12));

  // Water gradient: deep colorA at the floor rising to colorB in lit areas.
  float depth = smoothstep(-0.7, 0.7, uv.y) * 0.5 + 0.5 * wash;
  vec3 water = mix(uColorA, uColorB, depth);

  // Add the caustic filaments as colorC light on top of the water, scaled by the
  // wash so highlights cluster where the water is already brighter.
  float lit = caustic * (0.55 + 0.75 * wash);
  vec3 col = water + uColorC * lit;

  // A second, very soft bloom of the brightest cores for that wet glint.
  col += uColorC * pow(clamp(caustic, 0.0, 1.0), 3.0) * 0.35;

  // Gentle vignette frames the pool of light without hard edges.
  float vig = 1.0 - 0.25 * dot(vUv - 0.5, vUv - 0.5);
  col *= vig;

  // Dither last to kill 8-bit banding in the smooth dark water gradient.
  fragColor = vec4(col + dither(fragCoord), 1.0);
}
