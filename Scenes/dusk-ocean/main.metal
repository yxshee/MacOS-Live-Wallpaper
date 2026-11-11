// A calm sea at sunset: sky gradient, sun with glow, perspective waves and a glittering sun path.
//
// Dusk Ocean by Adil Kairolla (MacPaper Engine)
// https://github.com/adilkairolla/macpaper-engine/tree/main/Samples/Dusk%20Ocean.macpaper
// This content is under the MIT License (repository LICENSE: "Copyright (c) 2026 Adil Kairolla").
//
// The sample's second pass, shaders/film-grain.metal, is headed "Fine animated film grain."
// and is folded in at the end of mainImage below.
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the original:
//  - The MacPaper entry point effect(Pixel, Frame, Params, Inputs) became mainImage; frame.time
//    is iTime, and the canvas aspect is iResolution.x / iResolution.y.
//  - The original works in a top-left-origin 0..1 space; uv is flipped from our bottom-left
//    fragCoord to it, so the picture is the same way up.
//  - The engine helpers the shader calls (mp_hash, mp_noise, mp_fbm, mp_rotate, mp_luma, from
//    Sources/MacPaper/Render/ShaderSource.swift in the same repository) are copied in unchanged.
//  - The exposed parameters are constants at their default values: sun (0.62, 0.47), horizon
//    0.56, speed 0.6, waves 0.35, scale 1.0, and the four "Golden" colours #2a3e7a, #f39a6b,
//    #ffcf8a, #122046. The sun is not draggable.
//  - Two smoothstep calls whose edges ran high-to-low (undefined in MSL/GLSL) are written as
//    one minus the low-to-high form, which is the same curve.
//  - The two passes are merged: the ocean colour is clamped to 0..1 (the original's intermediate
//    target was 8-bit) and then the film grain is applied (amount 0.12, size 1.5). The grain is
//    re-drawn 4 times a second instead of every frame (it was a new pattern 24 times a second),
//    so it does not shimmer on a desktop; its strength and cell size are unchanged.
//  - The sun, waves and clouds move exactly as fast as in the original.

#define SUN        vec2(0.62, 0.47)
#define HORIZON    0.56
#define SPEED      0.6
#define WAVES      0.35
#define SCALE      1.0
#define COL_HIGH   (vec3(42.0, 62.0, 122.0) / 255.0)     // #2a3e7a
#define COL_LOW    (vec3(243.0, 154.0, 107.0) / 255.0)   // #f39a6b
#define COL_SUN    (vec3(255.0, 207.0, 138.0) / 255.0)   // #ffcf8a
#define COL_DEEP   (vec3(18.0, 32.0, 70.0) / 255.0)      // #122046
#define GRAIN_AMOUNT 0.12
#define GRAIN_SIZE   1.5

// ---- MacPaper engine helpers (ShaderSource.swift), unchanged ----

float mp_hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float mp_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = mp_hash(i);
    float b = mp_hash(i + vec2(1.0, 0.0));
    float c = mp_hash(i + vec2(0.0, 1.0));
    float d = mp_hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float mp_fbm(vec2 p, int octaves) {
    float v = 0.0, a = 0.5, norm = 0.0;
    for (int i = 0; i < min(octaves, 10); i++) {
        v += a * mp_noise(p);
        norm += a;
        p = p * 2.03 + vec2(17.1, 9.2);
        a *= 0.5;
    }
    return v / max(norm, 1e-4);
}

float mp_luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec2 mp_rotate(vec2 p, float a) {
    float s = sin(a), c = cos(a);
    return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}

// ---- Dusk Ocean (shaders/ocean.metal) ----

float wave_height(vec2 p, float t) {
    float h = 0.0;
    float a = 0.5;
    vec2 d = vec2(1.0, 0.25);
    for (int i = 0; i < 5; i++) {
        h += a * sin(dot(p, d) + t * (1.0 + float(i) * 0.35));
        d = mp_rotate(d, 1.1) * 1.85;
        a *= 0.5;
    }
    return h + (mp_fbm(p * 0.6 + t * 0.05, 3) - 0.5) * 0.6;
}

void mainImage(thread vec4& fragColor, vec2 fragCoord)
{
    float aspect = iResolution.x / iResolution.y;
    vec2 uv = vec2(fragCoord.x / iResolution.x, 1.0 - fragCoord.y / iResolution.y);   // origin top-left, as the original
    float horizon = HORIZON;
    vec2 sun = SUN;
    float t = iTime * SPEED;
    vec3 col = vec3(0.0);

    if (uv.y < horizon) {
        float h = clamp((horizon - uv.y) / horizon, 0.0, 1.0);
        col = mix(COL_LOW, COL_HIGH, pow(h, 0.6));
        float d = length((uv - sun) * vec2(aspect, 1.0));
        col += COL_SUN * (exp(-d * 9.0) * 0.6 + exp(-d * 40.0) * 0.6);
        col = mix(col, vec3(1.0, 0.97, 0.9), 1.0 - smoothstep(0.03, 0.035, d));
        float clouds = mp_fbm(vec2(uv.x * aspect * 1.4 + t * 0.01, uv.y * 7.0), 5);
        float band = smoothstep(horizon * 0.25, horizon * 0.85, uv.y) * (1.0 - smoothstep(horizon * 0.8, horizon, uv.y));
        col = mix(col, COL_LOW * 0.55 + COL_SUN * 0.25, smoothstep(0.55, 0.75, clouds) * band * 0.8);
    } else {
        float depth = (uv.y - horizon) / (1.0 - horizon);
        float z = 1.0 / max(depth, 0.004);
        vec2 p = vec2((uv.x - sun.x) * aspect * z * 2.0, z * 3.0) * SCALE;
        float e = 0.05;
        float h0 = wave_height(p, t);
        float hx = wave_height(p + vec2(e, 0.0), t);
        float hz = wave_height(p + vec2(0.0, e), t);
        vec3 n = normalize(vec3(-(hx - h0) / e * WAVES, 1.0, -(hz - h0) / e * WAVES * 2.0));
        float fres = pow(1.0 - clamp(n.y * 0.9, 0.0, 1.0), 3.0);
        vec3 sky = mix(COL_LOW, COL_HIGH, 0.3);
        vec3 water = mix(COL_DEEP, sky, 0.25 + fres * 0.6);
        float sunX = (uv.x - sun.x) * aspect;
        float path = exp(-abs(sunX) * (6.0 + depth * 10.0) / max(depth, 0.08));
        float glitter = smoothstep(0.55, 0.95, n.x * 0.5 + n.z * 0.5 + 0.5) * path;
        water += COL_SUN * (path * 0.35 + glitter * 1.6);
        float haze = exp(-depth * 6.0);
        col = mix(water, COL_LOW, haze * 0.7);
    }

    // ---- Fine film grain (shaders/film-grain.metal), folded in ----
    col = clamp(col, 0.0, 1.0);
    vec2 cell = floor(vec2(fragCoord.x, iResolution.y - fragCoord.y) / max(GRAIN_SIZE, 1.0));
    float frameStep = floor(iTime * 4.0);
    float n = mp_hash(cell + fract(frameStep * 0.6180339) * 97.0) - 0.5;
    float l = mp_luma(col);
    float weight = 1.0 - abs(l - 0.5) * 1.2;
    col = col + n * GRAIN_AMOUNT * 0.25 * weight;

    fragColor = vec4(col, 1.0);
}
