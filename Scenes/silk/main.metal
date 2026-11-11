// Flowing silk: domain-warped noise shaded like folded fabric. Pulses with music when audio-reactive is on.
//
// Silk, from MacPaper Engine (Samples/Silk.macpaper/shaders/silk.metal) by Adil Kairolla.
// https://github.com/adilkairolla/macpaper-engine/blob/main/Samples/Silk.macpaper/shaders/silk.metal
// The file carries no licence header of its own; the repository it was written for is
// "MIT License, Copyright (c) 2026 Adil Kairolla" (LICENSE at the repository root).
// The noise helpers (mp_hash, mp_noise, mp_fbm) are the same repository's built-in
// helpers from Sources/MacPaper/Render/ShaderSource.swift. The q / r / f domain-warp
// layout follows Inigo Quilez's "Warping" article, https://iquilezles.org/articles/warp/
// (his code snippets are stated to be MIT licensed). See LICENSE in this folder.
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the original:
//  - the MacPaper engine wrapper is gone: effect(Pixel, Frame, Params, Inputs) became mainImage,
//    and the engine's mp_hash, mp_noise and mp_fbm helpers are copied in unchanged
//  - the exposed parameters are constants at their defaults: scale 1.6, pulse 1.0, and the
//    default "Orchid" palette #1a0b3d / #6b2fa8 / #ff7ab6. The one exception is speed:
//    0.5 instead of the default 1.0, because at 1.0 the picture has changed completely
//    within about 5 seconds, which is lively for a desktop background (about 10 at 0.5)
//  - the audio level is a constant 0, so the sheen strength is the calm 0.35
//  - the engine's top-left, y-down pixel coordinates are rebuilt from our bottom-left
//    fragCoord, and the horizontal aspect uses the real output size instead of the
//    wallpaper canvas size, so portrait and ultrawide displays are not stretched
// The shading maths and every other constant are untouched.

static inline float mp_hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float mp_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = mp_hash(i);
    float b = mp_hash(i + float2(1, 0));
    float c = mp_hash(i + float2(0, 1));
    float d = mp_hash(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float mp_fbm(float2 p, int octaves) {
    float v = 0.0, a = 0.5, norm = 0.0;
    for (int i = 0; i < min(octaves, 10); i++) {
        v += a * mp_noise(p);
        norm += a;
        p = p * 2.03 + float2(17.1, 9.2);
        a *= 0.5;
    }
    return v / max(norm, 1e-4);
}

void mainImage(thread vec4& fragColor, vec2 fragCoord)
{
    // Parameters of the original at their defaults.
    const float pScale = 1.6;
    const float pSpeed = 0.5;   // the original's default is 1.0; halved so it suits a desktop
    const float pPulse = 1.0;
    const float audioLevel = 0.0;
    const vec3 colA = vec3(26.0, 11.0, 61.0) / 255.0;     // #1a0b3d
    const vec3 colB = vec3(107.0, 47.0, 168.0) / 255.0;   // #6b2fa8
    const vec3 colC = vec3(255.0, 122.0, 182.0) / 255.0;  // #ff7ab6

    vec2 screen = fragCoord / iResolution.xy;              // 0..1, origin bottom left
    vec2 uv = vec2(screen.x, 1.0 - screen.y);              // the original's uv: origin top left, y down
    float aspect = iResolution.x / iResolution.y;

    vec2 p = vec2(uv.x * aspect, uv.y) * pScale;
    float t = iTime * pSpeed * 0.08;
    vec2 q = vec2(mp_fbm(p + vec2(0.0, t), 5), mp_fbm(p + vec2(5.2, 1.3 - t), 5));
    vec2 r = vec2(mp_fbm(p + 3.0 * q + vec2(1.7, 9.2) + t * 0.6, 5), mp_fbm(p + 3.0 * q + vec2(8.3, 2.8) - t * 0.4, 5));
    float f = mp_fbm(p + 3.5 * r, 5);
    float folds = sin(f * 14.0 + r.x * 6.0) * 0.5 + 0.5;
    vec3 col = mix(colA, colB, saturate(f * 1.4));
    col = mix(col, colC, saturate(length(q) * 0.9 - 0.2));
    col *= 0.65 + 0.55 * pow(folds, 1.5);
    float sheen = pow(folds, 18.0) * (0.35 + audioLevel * pPulse * 1.5);
    col += sheen * mix(colC, vec3(1.0), 0.6);
    vec2 v = screen - 0.5;
    col *= 1.0 - dot(v, v) * 0.8;
    fragColor = vec4(col, 1.0);
}
