// Northern Lights, from the MacPaper Engine sample wallpaper "Northern Lights.macpaper"
// https://github.com/adilkairolla/macpaper-engine/tree/main/Samples/Northern%20Lights.macpaper
// Copyright (c) 2026 Adil Kairolla. MIT License, see the LICENSE file beside this one.
//
// The sample is five layers: a sky shader, a "stars" particle emitter, an aurora
// shader (screen blend), a mountains shader and a fog shader. The first line of
// each original layer shader read:
//   sky.metal:       Night sky gradient that brightens slightly toward the horizon.
//   aurora.metal:    Curtains of aurora rippling over the sky.
//   mountains.metal: Layered mountain ridges in silhouette, rim-lit by the aurora.
//   fog.metal:       Low rolling fog that thickens toward the bottom of the frame.
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the original:
//  - The five layers are composited in this one pass, in the original order and with
//    the original blend modes (sky, stars added, aurora screened, mountains, fog).
//    Where mountains fully cover the sky, the layers beneath are skipped; the
//    picture is the same.
//  - effect(Pixel, Frame, Params, Inputs) became mainImage; the sample's default
//    parameter values (colours, heights, speeds, intensity) are constants below.
//    mp_hash, mp_noise and mp_fbm are the engine's helper functions, copied from its
//    shader preamble (Sources/MacPaper/Render/ShaderSource.swift) unchanged.
//  - The "stars" particle layer (900 particles, area 0..1 x 0..0.65 of the canvas,
//    size 0.0008..0.0024, glow shape, additive, 6..12 s lifetimes with a 20% fade in
//    and out, fully modulated twinkle) is drawn per pixel from a jittered grid of
//    stars that live, fade, respawn elsewhere and twinkle the same way. The twinkle
//    is half as fast as the original (1 to 3.5 rad/s instead of 2 to 7) so it suits
//    a desktop. Stars are kept at least 1.25 pixels wide so they survive a low scale.
//  - The engine's slow camera sway ("drift" 0.35 with each layer's parallax factor)
//    is kept, computed from iTime. Pointer parallax, audio and daylight inputs are
//    not used (the sample does not use them either).
//  - The canvas is always 16:9 and fills the screen's height. On screens wider than
//    that the landscape continues sideways instead of being cropped top and bottom;
//    on narrower screens the middle of the canvas is shown, as in the original.
//  - smoothstep(0.006, 0.0, x) and smoothstep(0.35, 0.0, r) with their edges in
//    descending order are written as 1.0 - smoothstep(0.0, 0.006, x) and
//    1.0 - smoothstep(0.0, 0.35, r), which is the same curve.
//  - The mountain ridge edges, hard in the original, are anti-aliased over one drawn
//    pixel, so that the scene can be drawn at a reduced scale without stair-steps.
//  - Coordinates are flipped to the engine's top-left canvas inside mainImage.

#define CANVAS_ASPECT (3840.0 / 2160.0)

// Sample defaults ------------------------------------------------------------------

// sky
#define SKY_TOP      (vec3(3.0, 6.0, 15.0) / 255.0)       // #03060f
#define SKY_HORIZON  (vec3(19.0, 37.0, 66.0) / 255.0)     // #132542

// stars (particles, preset "stars" with count 900, area [0,0,1,0.65], size [0.0008,0.0024])
#define STAR_COUNT       900.0
#define STAR_AREA_BOTTOM 0.65
#define STAR_SIZE_MIN    0.0008
#define STAR_SIZE_MAX    0.0024
#define STAR_LIFE_MIN    6.0
#define STAR_LIFE_MAX    12.0
#define STAR_FADE        0.2
#define STAR_TWINKLE_RATE 0.5     // 1.0 = the original's speed
#define STAR_MIN_PIXELS  1.25
#define STAR_PRESENCE    0.5      // chance that a grid cell holds a star during one life

// aurora
#define AURORA_INTENSITY 1.0
#define AURORA_HEIGHT    0.3
#define AURORA_SPEED     1.0
#define AURORA_COLOR_A   (vec3(61.0, 255.0, 176.0) / 255.0)   // #3dffb0
#define AURORA_COLOR_B   (vec3(138.0, 92.0, 255.0) / 255.0)   // #8a5cff

// mountains
#define MOUNTAIN_HEIGHT  0.7
#define MOUNTAIN_COLOR   (vec3(27.0, 42.0, 68.0) / 255.0)     // #1b2a44
#define MOUNTAIN_RIM     (vec3(111.0, 227.0, 196.0) / 255.0)  // #6fe3c4

// fog
#define FOG_DENSITY      0.45
#define FOG_HEIGHT       0.82
#define FOG_SPEED        0.6
#define FOG_COLOR        (vec3(159.0, 183.0, 214.0) / 255.0)  // #9fb7d6

// camera sway: scene "drift" and each layer's "parallax"
#define DRIFT            0.35
#define PARALLAX_STARS    0.004
#define PARALLAX_AURORA   0.006
#define PARALLAX_MOUNTAIN 0.018
#define PARALLAX_FOG      0.03

// Engine helpers (MacPaper Engine, ShaderSource.swift) -------------------------------

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
    float b = mp_hash(i + vec2(1, 0));
    float c = mp_hash(i + vec2(0, 1));
    float d = mp_hash(i + vec2(1, 1));
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

// The canvas position of a layer's pixel: the engine's mp_layer_uv.
vec2 layerUV(vec2 canvasUV, vec2 shift, float zoom) {
    return (canvasUV - shift - 0.5) / zoom + 0.5;
}

// sky.metal: Night sky gradient that brightens slightly toward the horizon.
vec3 skyLayer(vec2 uv, vec2 pixelCoord) {
    vec3 col = mix(SKY_TOP, SKY_HORIZON, pow(uv.y, 1.6));
    col += (mp_hash(pixelCoord) - 0.5) * 0.012;
    return col;
}

// stars: the "stars" particle emitter. q is x in canvas heights, y in canvas uv (0 at top).
float starRnd(vec2 id, float gen, float k) {
    return mp_hash(vec2(id.x * 0.618 + gen * 13.37 + k, id.y * 0.314 + gen * 7.13 + k * 7.13));
}

float starLayer(vec2 q) {
    if (q.y > STAR_AREA_BOTTOM + 0.01) return 0.0;
    float cell = sqrt(STAR_PRESENCE * CANVAS_ASPECT * STAR_AREA_BOTTOM / STAR_COUNT);
    vec2 g = q / cell;
    vec2 base = floor(g);
    vec2 f = g - base;
    vec2 nb = vec2(f.x < 0.5 ? -1.0 : 1.0, f.y < 0.5 ? -1.0 : 1.0);
    float total = 0.0;
    for (int k = 0; k < 4; k++) {
        vec2 id = base + vec2((k & 1) != 0 ? nb.x : 0.0, (k & 2) != 0 ? nb.y : 0.0);
        float period = mix(STAR_LIFE_MIN, STAR_LIFE_MAX, mp_hash(id + vec2(3.7, 1.9)));
        float tt = (iTime + mp_hash(id + vec2(11.3, 5.1)) * period) / period;
        float gen = floor(tt);
        float life = tt - gen;
        float gm = mod(gen, 251.0);
        if (starRnd(id, gm, 0.0) >= STAR_PRESENCE) continue;
        vec2 pos = (id + vec2(starRnd(id, gm, 1.0), starRnd(id, gm, 2.0))) * cell;
        if (pos.y > STAR_AREA_BOTTOM) continue;
        float size = mix(STAR_SIZE_MIN, STAR_SIZE_MAX, starRnd(id, gm, 6.0));
        float seed = starRnd(id, gm, 7.0);
        float radius = max(size * iResolution.y, STAR_MIN_PIXELS);
        float r = length(q - pos) * iResolution.y / radius;
        if (r >= 1.0) continue;
        float fadeIn = saturate(life / STAR_FADE);
        float fadeOut = saturate((1.0 - life) / STAR_FADE);
        float tw = 1.0 - (0.5 + 0.5 * sin(iTime * STAR_TWINKLE_RATE * (2.0 + seed * 5.0) + seed * 40.0));
        float shape = exp(-r * r * 4.0) + 0.6 * (1.0 - smoothstep(0.0, 0.35, r));
        total += saturate(shape) * fadeIn * fadeOut * tw;
    }
    return total;
}

// aurora.metal: Curtains of aurora rippling over the sky. Returns straight (not premultiplied) RGBA.
vec4 auroraLayer(vec2 uv) {
    float t = iTime * AURORA_SPEED;
    float aspect = CANVAS_ASPECT;
    if (uv.y > AURORA_HEIGHT + 0.4) return vec4(0.0);
    vec3 acc = vec3(0.0);
    float alpha = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float x = uv.x * aspect * (0.8 + fi * 0.3) + fi * 3.7;
        float wave = mp_fbm(vec2(x * 0.5 + t * 0.04, fi * 2.0 + t * 0.015), 4);
        float base = AURORA_HEIGHT + (wave - 0.5) * 0.3 + fi * 0.05;
        float d = uv.y - base;
        float below = exp(-max(d, 0.0) * 22.0);
        float above = smoothstep(-0.28, 0.0, d) * (0.4 + 0.6 * smoothstep(-0.28, -0.05, d));
        float folds = 0.75 + 0.25 * mp_noise(vec2(x * 9.0 + wave * 6.0, t * 0.3 + fi));
        float a = below * above * folds * (0.55 - fi * 0.12);
        vec3 c = mix(AURORA_COLOR_A, AURORA_COLOR_B, saturate(-d * 4.0 + 0.2 * fi));
        acc += c * a;
        alpha += a;
    }
    float glow = saturate(alpha * AURORA_INTENSITY);
    return vec4(acc / max(alpha, 1e-3), glow);
}

// mountains.metal: Layered mountain ridges in silhouette, rim-lit by the aurora.
float ridge(float x, float seed, float height, float rough) {
    float n = mp_fbm(vec2(x * rough + seed, seed * 3.1), 5);
    float peaks = 1.0 - abs(mp_noise(vec2(x * rough * 1.3 + seed * 7.0, seed)) * 2.0 - 1.0);
    return height - (n - 0.35) * 0.45 - peaks * peaks * 0.12;
}

vec4 mountainsLayer(vec2 uv) {
    float x = uv.x * CANVAS_ASPECT;
    float y = uv.y;
    // Ridges never rise more than ~0.35 above their base height, so the sky above costs nothing.
    if (y < MOUNTAIN_HEIGHT - 0.4) return vec4(0.0);
    vec4 m = vec4(0.0);   // premultiplied
    float pixel = 1.0 / iResolution.y;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float top = ridge(x, 4.0 + fi * 11.0, MOUNTAIN_HEIGHT + fi * 0.08, 1.4 + fi * 0.7);
        // The original switches from sky to ridge at y > top. Here that edge is
        // spread over one drawn pixel so a low render scale does not stair-step.
        float cover = saturate((y - top) / pixel + 0.5);
        if (cover > 0.0) {
            float d = max(y - top, 0.0);
            float shade = mix(0.55, 0.12, fi / 2.0) * (1.0 - smoothstep(0.0, 0.35, d) * 0.5);
            vec3 c = MOUNTAIN_COLOR * shade + MOUNTAIN_RIM * (1.0 - smoothstep(0.0, 0.006, d)) * (0.35 - fi * 0.1);
            float fog = exp(-d * 6.0) * (0.3 - fi * 0.08);
            m = vec4(mix(c, MOUNTAIN_RIM * 0.4, fog) * cover, cover) + m * (1.0 - cover);
        }
    }
    return m;
}

// fog.metal: Low rolling fog that thickens toward the bottom of the frame.
vec4 fogLayer(vec2 uv) {
    float band = smoothstep(FOG_HEIGHT - 0.35, FOG_HEIGHT + 0.25, uv.y);
    if (band <= 0.0) return vec4(0.0);
    vec2 p = vec2(uv.x * CANVAS_ASPECT, uv.y) * 2.2;
    float t = iTime * FOG_SPEED;
    float n = mp_fbm(p + vec2(t * 0.08, 0.0), 5);
    float n2 = mp_fbm(p * 2.1 - vec2(t * 0.05, t * 0.01), 4);
    float density = saturate((n * 0.7 + n2 * 0.5 - 0.35) * 2.0) * band * FOG_DENSITY;
    return vec4(FOG_COLOR, density);
}

void mainImage(thread vec4& fragColor, vec2 fragCoord)
{
    // Top-left origin, 0..1 over the screen.
    vec2 s = vec2(fragCoord.x / iResolution.x, 1.0 - fragCoord.y / iResolution.y);
    // The 16:9 canvas fills the screen's height; x is in canvas heights, centred.
    float X = 0.5 * CANVAS_ASPECT + (s.x - 0.5) * (iResolution.x / iResolution.y);
    vec2 canvasUV = vec2(X / CANVAS_ASPECT, s.y);

    // Slow camera sway (the scene's "drift"), in the range -DRIFT..DRIFT on each axis.
    vec2 sway = vec2(sin(iTime * 0.21) * 0.7 + sin(iTime * 0.13 + 1.3) * 0.3,
                     cos(iTime * 0.17) * 0.6 + sin(iTime * 0.09 + 0.4) * 0.4) * DRIFT;
    sway = clamp(sway, -1.0, 1.0);

    vec2 uvAurora   = layerUV(canvasUV, sway * PARALLAX_AURORA,   1.0 + 2.0 * PARALLAX_AURORA);
    vec2 uvMountain = layerUV(canvasUV, sway * PARALLAX_MOUNTAIN, 1.0 + 2.0 * PARALLAX_MOUNTAIN);
    vec2 uvFog      = layerUV(canvasUV, sway * PARALLAX_FOG,      1.0 + 2.0 * PARALLAX_FOG);

    // mountains (premultiplied): where fully opaque, nothing below shows through
    vec4 mtn = mountainsLayer(uvMountain);
    vec3 col = mtn.rgb;
    if (mtn.a < 0.999) {
        vec3 behind = skyLayer(canvasUV, vec2(fragCoord.x, iResolution.y - fragCoord.y));
        // stars: additive
        vec2 q = vec2(X - sway.x * PARALLAX_STARS * CANVAS_ASPECT, s.y - sway.y * PARALLAX_STARS);
        behind = saturate(behind + vec3(starLayer(q)));
        // aurora: screen
        vec4 au = auroraLayer(uvAurora);
        vec3 src = au.rgb * au.a;
        behind = src + behind * (1.0 - src);
        col += behind * (1.0 - mtn.a);
    }
    // fog: normal
    vec4 fg = fogLayer(uvFog);
    col = mix(col, fg.rgb, fg.a);

    fragColor = vec4(col, 1.0);
}
