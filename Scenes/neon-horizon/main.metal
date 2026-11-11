//! title: Neon Horizon
//! order: 7
//! bloom: 0.14
//! tags: Neon
//
// "Neon Horizon": synthwave at night, in hot pink, teal and cyan.
//   • sky: indigo overhead fading to magenta at the horizon, a few stars, slow thin
//     cloud streaks drifting across
//   • a huge striped sun, pink-white to hot pink, its gaps sliding slowly downward
//   • two mountain ridges framing a valley, dark, edged with glowing cyan / pink rim light
//   • a wet black floor with a perspective neon grid scrolling toward the viewer
//     (analytically antialiased, fading into haze before it can moire), mirroring the
//     sun, mountains and sky with rippled, fresnel-weighted reflections
//   • a hot horizon line and a haze band where the floor meets the sky
//   bake – rgb: seamlessly tiling fBm (ripples, clouds), a: starfield.
// Everything is laid out per display (units of display height, y up).
// Motion uses the scene clock (U.target.z); every period divides a day evenly.
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the
// original (Scenes/NeonHorizon.metal, plus the helpers it uses from Scenes/Common.metal):
//   - ShaderDesk's engine wrapper is gone. The two entry points (scene_bake and
//     scene_frame) are now one mainImage(); its uniforms become iResolution and
//     iTime, and the picture is laid out in display heights from fragCoord
//     (bottom-left origin, as the original already was).
//   - The baked texture is noise.png (iChannel0): the same seamlessly tiling fBm
//     (rgb) that scene_bake computes, made once with the same maths (24 x 16 cells).
//     Its alpha starfield is computed per pixel instead, laid out as on a display
//     1000 points high so the stars look the same at any render scale.
//   - The scene clock is iTime wrapped at 1200 s; every period in the scene divides it.
//   - ShaderDesk's shared bloom pass (//! bloom: 0.14) and its dithering do not
//     exist here. The tone map (1 - exp(-1.15 c)) and the sRGB encoding it ends
//     with are applied in mainImage().
//   - Constants are #defines, GLSL type names are used, the helpers (hash11, hash12,
//     hash22, noise1, starLayer) are copied in, and the per-display seed and the
//     brightness setting are fixed at 0 and 1.
//   - Nothing else was changed: the colours, shapes, step counts and every speed
//     (grid scroll, sun stripes, cloud drift, ripples) are the author's.

#define HORIZON 0.40               // horizon height (display heights from the bottom)
#define GRID_SPEED 0.5             // grid cells per second toward the viewer

#define PINK vec3(1.00, 0.10, 0.55)
#define CYAN vec3(0.05, 0.85, 1.00)
#define TEAL vec3(0.00, 0.55, 0.55)

#define STAR_HEIGHT 1000.0         // stars are laid out as on a display this many points high
#define STAR_SEED 0.0

// ---- helpers from ShaderDesk's Scenes/Common.metal ----------------------------------
float hash11(float x) {
    x = fract(x * 0.1031);
    x *= x + 33.33;
    x *= x + x;
    return fract(x);
}

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

float noise1(float x) {
    float i = floor(x), f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(hash11(i), hash11(i + 1.0), u);
}

// One layer of randomly placed stars on a jittered grid (cell size in points).
// Returns the summed intensity (the original also summed a colour that this scene never used).
float starLayer(vec2 pt, float cell, float prob, float bMin, float bMax, float bPow,
                float sizePt, float minSigma, float seed) {
    vec2 c = floor(pt / cell);
    float total = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 id = c + vec2(float(i), float(j));
            if (hash12(id + seed * 1.13) > prob) continue;
            vec2 sp = (id + 0.1 + 0.8 * hash22(id * 1.37 + seed + 17.0)) * cell;
            vec2 d = pt - sp;
            float b = bMin + (bMax - bMin) * pow(hash12(id + seed * 3.1 + 5.0), bPow);
            float sigma = max(sizePt * (0.6 + 0.8 * sqrt(b / bMax)), minSigma);
            total += b * exp(-dot(d, d) / (2.0 * sigma * sigma));
        }
    }
    return total;
}

// starfield at (x, y) in display heights; the original bakes this into the alpha channel
float starField(float x, float y, float px) {
    vec2 pt = vec2(x, y) * STAR_HEIGHT;
    float minSigma = 0.55 * px * STAR_HEIGHT;
    float stars = 0.0;
    stars += starLayer(pt, 9.0, 0.10, 0.02, 0.10, 3.0, 0.42, minSigma, STAR_SEED + 6.0);
    stars += starLayer(pt, 30.0, 0.30, 0.04, 0.45, 5.0, 0.55, minSigma, STAR_SEED + 3.0);
    return stars;
}

// mountain ridge height at x (display heights), with a valley around the sun
float ridgeH(float x, float cx, float seed, float base, float amp, float valley) {
    float h = 0.0, a = 0.5, f = 1.0;
    for (int i = 0; i < 6; i++) {
        float n = noise1(x * f * 4.0 + seed * 13.1);
        h += a * (1.0 - abs(2.0 * n - 1.0));          // ridged: sharp peaks
        a *= 0.5; f *= 2.1;
    }
    float v = smoothstep(valley * 0.35, valley, abs(x - cx));
    return base + amp * h * (0.15 + 0.85 * v);
}

// everything above the horizon, at (x, y) in display heights. `blurry` softens the
// thin details (used for the reflection).
vec3 skyColor(float x, float y, float cx, float aspect, float t, float blurry, float px) {
    float hy = y - HORIZON;                                   // height above horizon
    float s = saturate(hy / (1.0 - HORIZON));
    vec3 col = mix(vec3(0.42, 0.04, 0.34), vec3(0.10, 0.02, 0.20), pow(s, 0.45));
    col = mix(col, vec3(0.012, 0.006, 0.035), smoothstep(0.35, 1.0, s));
    // stars (not reflected)
    if (blurry < 0.5 && s > 0.12) {
        col += vec3(0.9, 0.85, 1.0) * starField(x, y, px) * smoothstep(0.12, 0.45, s);
    }

    // thin cloud streaks drifting right, silhouetted against the sun
    {
        float cy = hy;
        float drift = t / 1200.0;                             // 1200 s per wrap
        float c1 = iChannel0.sample(lwRepeat, vec2(x / aspect * 0.8 + drift, cy * 9.0)).b;
        float band = exp(-pow((cy - 0.13) / 0.035, 2.0)) + 0.7 * exp(-pow((cy - 0.24) / 0.022, 2.0));
        float cl = smoothstep(0.52, 0.72, c1) * band;
        col = mix(col, vec3(0.05, 0.01, 0.10) + PINK * 0.06, saturate(cl * 0.7));
    }

    // sun
    vec2 sc = vec2(cx, HORIZON + 0.16);
    const float SR = 0.24;
    vec2 d = vec2(x, y) - sc;
    float dr = length(d) / SR;
    float glow = exp(-max(dr - 1.0, 0.0) * 3.5) * 0.35 + exp(-max(dr - 1.0, 0.0) * 12.0) * 0.4;
    col += PINK * glow * 0.8;
    if (dr < 1.02) {
        float v = saturate((d.y / SR) * 0.5 + 0.5);           // 0 bottom, 1 top
        vec3 sun = mix(vec3(0.95, 0.02, 0.45), vec3(1.0, 0.30, 0.45), smoothstep(0.1, 0.75, v));
        sun = mix(sun, vec3(1.0, 0.62, 0.42), smoothstep(0.7, 1.0, v)) * 1.05;
        // stripes over the lower half, gaps widening toward the bottom, sliding down
        // (7 stripes per sun radius, 16 s per stripe)
        float band = saturate((0.55 - v) / 0.55);             // 0 at 55% height, 1 at bottom
        float f = fract(d.y / SR * 7.0 + t / 16.0);
        float gap = 0.06 + 0.55 * band;
        float aaS = px / SR * 7.0 * 1.2 + blurry * 0.08;
        float cut = band > 0.0 ? smoothstep(gap - aaS, gap + aaS, f) : 1.0;
        float a = saturate((1.0 - dr) * SR / (px * 1.2 + blurry * 0.003) + 0.5) * cut;
        col = mix(col, sun, a);
    }

    // mountains: far ridge (teal rim), near ridge (pink rim)
    float hf = ridgeH(x, cx, 1.7, HORIZON + 0.015, 0.20, 0.36);
    float hn = ridgeH(x * 0.8 + 3.0, cx * 0.8 + 3.0, 4.3, HORIZON, 0.13, 0.52 * 0.8);
    float aaM = px * 1.2 + blurry * 0.004;
    if (y < hf + 0.12) {
        float inside = smoothstep(hf + aaM, hf - aaM, y);
        vec3 m = vec3(0.010, 0.012, 0.035) + TEAL * 0.05 * saturate((y - HORIZON) / max(hf - HORIZON, 0.03));
        col = mix(col, m, inside);
        float rim = exp(-abs(y - hf) / (px * 1.4 + blurry * 0.003));
        col += CYAN * rim * 1.6 + CYAN * exp(-max(y - hf, 0.0) / 0.01) * step(hf, y) * 0.12;
    }
    if (y < hn + 0.12) {
        float inside = smoothstep(hn + aaM, hn - aaM, y);
        vec3 m = vec3(0.008, 0.004, 0.02) + PINK * 0.03 * saturate((y - HORIZON) / max(hn - HORIZON, 0.03));
        col = mix(col, m, inside);
        float rim = exp(-abs(y - hn) / (px * 1.4 + blurry * 0.003));
        col += PINK * rim * 1.8 + PINK * exp(-max(y - hn, 0.0) / 0.012) * step(hn, y) * 0.10;
    }
    // haze just above the horizon
    col += vec3(0.9, 0.2, 0.7) * 0.18 * exp(-max(hy, 0.0) / 0.03);
    return col;
}

void mainImage(thread vec4& fragColor, vec2 fragCoord)
{
    float t = mod(iTime, 1200.0);                            // scene clock; every period divides 1200 s
    float H = iResolution.y;
    float aspect = iResolution.x / H;
    vec2 q = fragCoord / H;                                  // display heights, y up
    float cx = aspect * 0.5;
    float px = 1.0 / H;                                      // one pixel

    vec3 col = vec3(0.0);
    if (q.y >= HORIZON) {
        col = skyColor(q.x, q.y, cx, aspect, t, 0.0, px);
    } else {
        // ---- floor: perspective ground plane
        float dy = HORIZON - q.y;                             // below horizon
        const float CAM = 0.09;                               // camera height
        float z = CAM / max(dy, 1e-4);                        // depth
        float X = (q.x - cx) * z;                             // lateral world position
        vec2 gw = vec2(X * 22.0, z * 22.0 * 0.5 + t * GRID_SPEED);
        vec2 fw = fwidth(gw);
        vec2 gd = abs(fract(gw + 0.5) - 0.5);                 // distance to nearest line (cells)
        vec2 lineW = vec2(0.035, 0.05);
        vec2 core = 1.0 - smoothstep(lineW - fw, lineW + fw, gd);
        vec2 halo = exp(-gd / max(fw * 2.5 + 0.04, 1e-4));
        float fadeX = saturate(1.0 - fw.x * 1.6), fadeZ = saturate(1.0 - fw.y * 1.3);
        float near = smoothstep(0.0, 0.5, dy / HORIZON);      // 0 at horizon, 1 at bottom
        vec3 lineC = mix(PINK, CYAN, smoothstep(0.05, 0.9, near));
        vec3 grid = lineC * ((core.x + halo.x * 0.35) * fadeX + (core.y + halo.y * 0.35) * fadeZ) * 1.6;
        // intersections glow a little brighter
        grid += lineC * core.x * core.y * 1.5 * fadeX * fadeZ;

        // wet reflection: mirror the sky about the horizon, rippled, fresnel-weighted
        vec2 rq = vec2(q.x, HORIZON + dy);
        float rip = iChannel0.sample(lwRepeat, vec2(X * 0.6, z * 0.4 + t / 600.0)).r - 0.5;
        float rip2 = iChannel0.sample(lwRepeat, vec2(X * 2.3 + 0.3, z * 1.3 - t / 400.0)).g - 0.5;
        rq.x += (rip * 0.02 + rip2 * 0.008) * (0.3 + near);
        rq.y += abs(rip2) * 0.004 * near;
        vec3 refl = skyColor(rq.x, min(rq.y, 0.999), cx, aspect, t, 1.0, px);
        float fres = mix(0.40, 0.07, smoothstep(0.0, 0.7, near));
        vec3 floorC = vec3(0.006, 0.004, 0.016) + refl * fres;
        col = floorC + grid * mix(0.5, 1.0, near);
        // haze band where floor meets sky
        col += vec3(0.9, 0.2, 0.7) * 0.25 * exp(-dy / 0.012);
    }
    // the horizon line itself
    col += vec3(1.0, 0.55, 0.85) * 2.0 * exp(-abs(q.y - HORIZON) / (px * 1.5));

    // gentle vignette
    vec2 vc = (q - vec2(cx, 0.5)) / vec2(aspect, 1.0);
    col *= 1.0 - 0.35 * dot(vc, vc);

    // ShaderDesk's final stage: tone map, then sRGB-encode (no bloom pass here)
    col = select(col, vec3(0.0), isnan(col));
    col = max(1.0 - exp(-col * 1.15), 0.0);
    col = select(1.055 * pow(col, vec3(1.0 / 2.4)) - 0.055, col * 12.92, col <= 0.0031308);
    fragColor = vec4(col, 1.0);
}
