//! title: Abyss
//! order: 9
//! bloom: 0.18
//! tags: Ocean
//
// "Abyss": the deep ocean at the edge of the light.
//   • water fading from a faint teal glow overhead into black, with slow light shafts
//     fanning down from a surface far above
//   • bioluminescent jellyfish at several depths, swimming upward in pulses: each
//     contraction of the bell pushes it up, then it glides. Translucent bells with a
//     bright rim, radial canals, glowing gonads and a ring of marginal lights, trailing
//     rippling tentacles and frilled oral arms. They light up when the agent is busy.
//   • marine snow sinking past in three depths
// Everything is additive light (no sorting needed) and laid out per display (units of
// display height, y up). Motion uses the scene clock (U.target.z); every period divides
// a day evenly.
//
// Ported to Metal Shading Language for MacOS Live Wallpaper.
// Original: https://github.com/ilrein/shaderdesk/blob/main/Scenes/Abyss.metal
// (Ilia Reingold, ShaderDesk, MIT License; see the LICENSE file beside this one.)
//
// Changes from the original:
//   - The ShaderDesk engine wrapper is gone. The scene_frame entry point with its
//     Uniforms, Galaxy, Flare and bg arguments is now mainImage(). The display is the
//     whole render target: q = fragCoord / height (display heights, y up, bottom-left
//     origin) and one pixel is 1 / height.
//   - Scene clock (U.target.z) is mod(iTime, 86400.0), which is the same "wraps daily"
//     clock, so the loops stay seamless.
//   - Agent activity (U.motion.z) is a calm constant 0, so the jellyfish glow at their
//     idle level. The per-display seed (U.misc.w) is the first display's value, 0.
//   - Brightness (U.misc.x) is 1. present() from ShaderDesk's Common.metal is written
//     out at the end of mainImage (tone map, sRGB encode, 1/255 dither, NaN guard),
//     because the output here is display-ready.
//   - hash11, hash12 and hash22 are copied from ShaderDesk's Common.metal; they are
//     David Hoskins' "Hash without Sine" (https://www.shadertoy.com/view/4djSRW),
//     Copyright (c) 2014 David Hoskins, MIT; his notice is in the LICENSE file.
//   - Constants JELLIES and TAU are #defines (`constant` is reserved in Metal here),
//     `inline` is dropped, pow(x, 2.0) is written x * x where x can be negative, and
//     locals are initialised.
//   - ShaderDesk's post-process bloom (//! bloom: 0.18) is not available in a single
//     pass and is dropped. The scene's own soft halos around the bells remain.
//   The scene's maths, constants and timings are otherwise untouched.

#define JELLIES 8
#define TAU 6.28318530718

// ---- hashing (David Hoskins, "Hash without Sine", MIT) --------------------------------
float hash11(float x) {
    x = fract(x * 0.1031);
    x *= x + 33.33;
    x *= x + x;
    return fract(x);
}

float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

// ---- output (ShaderDesk's present(), non-HDR path) ------------------------------------
float3 abyssTonemap(float3 x) {
    return 1.0 - exp(-x * 1.15);
}

float3 abyssSrgbEncode(float3 c) {
    c = max(c, float3(0.0));
    return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= float3(0.0031308));
}

// periodic 1D noise: repeats every `P` (integer) units, so looping time never jumps
float pnoise1(float x, float P) {
    float i = floor(x), f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    float i0 = i - P * floor(i / P), i1 = i0 + 1.0;
    i1 -= P * floor(i1 / P);
    return mix(hash11(i0 + 0.37), hash11(i1 + 0.37), u);
}

// water colour with depth (y: 0 bottom .. 1 top of the display)
float3 water(float y) {
    float3 deep = float3(0.0004, 0.0016, 0.0050);
    float3 mid  = float3(0.0022, 0.0120, 0.0260);
    float3 top  = float3(0.0110, 0.0560, 0.0820);
    float3 c = mix(deep, mid, smoothstep(0.0, 0.65, y));
    return mix(c, top, smoothstep(0.55, 1.05, y));
}

// one layer of sinking marine snow. cell: display heights; fall: seconds per cell (must divide a day)
float3 snowLayer(float2 q, float cell, float fall, float prob, float size, float bright,
                 float t, float px, float seed) {
    float K = 86400.0 / fall;                                 // cells fallen per day (integer)
    float2 p = float2(q.x / cell, q.y / cell + t / fall);
    float2 id = floor(p);
    id.y -= K * floor(id.y / K);                              // wraps with the day: no jump
    if (hash12(id + seed) > prob) return float3(0.0);
    float2 h = hash22(id * 1.31 + seed);
    // a slow sideways wander, once per fall through a cell
    float wob = 0.18 * sin(TAU * (t / fall + h.x) + h.y * 6.0);
    float2 c = float2(0.2 + 0.6 * h.x + wob, 0.2 + 0.6 * h.y);
    float2 d = (fract(p) - c) * cell;
    float b = bright * (0.35 + 0.65 * hash12(id + seed + 9.1));
    float sigma = max(size * (0.6 + 0.8 * hash12(id + seed + 4.7)), px * 0.7);
    return float3(0.75, 0.90, 1.0) * b * (size / sigma) * exp(-dot(d, d) / (2.0 * sigma * sigma));
}

// hue palette for the jellies: cyan, violet, magenta, sea green, soft amber
float3 jellyTint(float h) {
    const float3 c[5] = { float3(0.10, 0.75, 1.00), float3(0.55, 0.30, 1.00), float3(1.00, 0.25, 0.75),
                          float3(0.15, 1.00, 0.65), float3(1.00, 0.60, 0.25) };
    int i = int(h * 4.999);
    return c[i];
}

// light from one jellyfish at local point p (units of bell radius, origin at the bell's
// mouth, y along its swimming axis). pr: pixel size in the same units.
float jelly(float2 p, float pr, float pulse, float t, float seed, thread float& core) {
    // bell: a dome that narrows and lengthens as it contracts
    float w = 1.0 - 0.16 * pulse, h = 0.78 + 0.12 * pulse;
    float light = 0.0;
    core = 0.0;

    if (p.y > -0.25) {
        float2 e2 = p / float2(w, h);
        float e = length(e2);
        // underside: the mouth curves up into the bell
        float lip = 0.22 * h * (1.0 - saturate(e2.x * e2.x));
        float aa = pr * 1.3;
        float inBell = smoothstep(1.0 + aa, 1.0 - aa, e) * smoothstep(lip - aa * 2.0, lip + aa * 2.0, p.y + 0.10 * h);
        if (inBell > 0.0) {
            float ang = atan2(p.x, p.y + 0.15);              // radial angle from the apex region
            float rim = pow(saturate(e), 7.0);                // translucent: the edges glow
            float canals = pow(0.5 + 0.5 * cos(ang * 16.0), 24.0) * smoothstep(0.25, 0.8, e);
            // four horseshoe gonads around the centre
            float ge = (e - 0.42) / 0.09;
            float gon = exp(-(ge * ge)) * pow(0.5 + 0.5 * cos(ang * 4.0 + seed * 3.0), 3.0);
            float body = 0.10 + 0.08 * (1.0 - e);
            light += inBell * (body + rim * 0.9 + canals * 0.35 + gon * 0.8);
            core += inBell * gon * 0.6;
        }
        // soft halo around the bell
        light += 0.10 * exp(-max(e - 1.0, 0.0) * 5.0) * step(1.0, e) * smoothstep(-0.25, 0.1, p.y);
        // marginal lights along the rim of the bell mouth
        float mx = p.x / w;
        if (abs(mx) < 1.05 && abs(p.y) < 0.25) {
            float n = 14.0;
            float s = (mx * 0.5 + 0.5) * n;
            float2 d = float2((fract(s) - 0.5) * 2.0 * w / n, p.y - 0.02);
            float sig = max(0.022, pr * 0.8);
            float tw = 0.6 + 0.4 * sin(TAU * t / 3.0 + floor(s) * 1.9 + seed * 7.0);
            light += 1.4 * tw * exp(-dot(d, d) / (2.0 * sig * sig)) * (0.022 / sig);
        }
    }

    if (p.y < 0.05) {
        float L = max(-p.y, 0.0);                            // distance down the trail
        // tentacles: thin, rippling, trailing from the margin
        const float LMAX = 4.2;
        if (L < LMAX + 0.2) {
            for (int i = 0; i < 9; i++) {
                float fi = float(i) / 8.0 * 2.0 - 1.0;
                float ph = hash11(seed * 9.3 + float(i) * 1.7);
                float len = LMAX * (0.55 + 0.45 * ph);
                if (L > len) continue;
                float x0 = fi * w * 0.92;
                float wave = sin(L * (3.0 + ph) - TAU * t / 6.0 + ph * TAU) * 0.10 * L
                           + sin(L * 7.0 - TAU * t / 4.0 + float(i)) * 0.03 * L;
                float xt = x0 * (1.0 + 0.10 * L) * (1.0 - 0.25 * pulse * saturate(1.0 - L)) + wave;
                float d = abs(p.x - xt);
                float tw = 0.012 * (1.0 - 0.7 * L / len);
                float sig = max(tw, pr * 0.7);
                float fade = pow(1.0 - L / len, 1.5);
                light += 0.9 * fade * (tw / sig) * exp(-d * d / (2.0 * sig * sig));
            }
        }
        // oral arms: three wide frilled ribbons in the middle
        if (L < 2.2) {
            for (int i = 0; i < 3; i++) {
                float fi = float(i) - 1.0;
                float sway = sin(L * 2.2 - TAU * t / 8.0 + fi * 2.0) * 0.12 * L;
                float xc = fi * 0.16 * (1.0 + 0.3 * L) + sway;
                float wid = (0.07 + 0.05 * sin(L * 26.0 - TAU * t / 5.0 + fi)) * (1.0 - L / 2.2 * 0.6);
                float d = abs(p.x - xc);
                float fade = pow(1.0 - L / 2.2, 1.2);
                float edge = smoothstep(wid + pr, wid - pr, d);
                float re = (d - wid) / max(0.015, pr);
                light += fade * (0.12 * edge + 0.35 * exp(-(re * re)) * edge);
                core += fade * 0.25 * edge * smoothstep(0.4, 0.0, L);
            }
        }
    }
    return light;
}

void mainImage(thread vec4& fragColor, vec2 fragCoord)
{
    float t = mod(iTime, 86400.0);                            // scene clock, wraps daily
    float H = iResolution.y;
    float aspect = iResolution.x / H;
    float2 q = fragCoord / H;                                 // display heights, y up
    float px = 1.0 / H;                                       // one pixel
    float act = 0.0;                                          // calm: no agent activity
    float seed = 0.0;                                         // first display's seed

    float3 col = water(q.y);

    // ---- light shafts fanning down from a point far above
    {
        float2 S = float2(aspect * 0.62, 2.4);
        float2 d = q - S;
        float ang = atan2(d.x, -d.y);                         // 0 straight down
        float a = ang * 40.0;
        float r = pnoise1(a + 3.0 * sin(TAU * t / 240.0), 400.0) * 0.6
                + pnoise1(a * 2.3 + 2.0 * sin(TAU * t / 150.0 + 1.0), 400.0) * 0.4;
        r = smoothstep(0.45, 0.95, r);
        float fall = smoothstep(-0.1, 1.0, q.y);             // shafts die out with depth
        col += float3(0.10, 0.35, 0.40) * r * fall * fall * 0.10;
        // a faint bright haze where the surface light comes from
        col += float3(0.05, 0.20, 0.24) * 0.10 * exp(-length(d * float2(0.8, 1.6)) * 1.2);
    }

    // ---- marine snow, far to near
    col += snowLayer(q, 0.022, 40.0, 0.30, 0.0010, 0.08, t, px, seed + 1.0);
    col += snowLayer(q, 0.045, 24.0, 0.28, 0.0016, 0.13, t, px, seed + 2.0);

    // ---- jellyfish
    float glowBoost = 1.0 + 0.6 * act;
    for (int j = 0; j < JELLIES; j++) {
        float fj = float(j) + seed * 13.0;
        float4 h = float4(hash11(fj * 1.13 + 0.1), hash11(fj * 2.71 + 0.2),
                          hash11(fj * 3.37 + 0.3), hash11(fj * 5.19 + 0.4));
        float depth = float(j) / float(JELLIES - 1);          // 0 far .. 1 near (drawn in any order)
        float r = mix(0.028, 0.105, depth * depth) * (0.85 + 0.3 * h.w);   // bell radius
        // one climb across the display every `loopT` seconds, in pulses of `pulseT`
        const float loops[4] = { 360.0, 432.0, 480.0, 540.0 };
        const float pulses[4] = { 4.0, 4.5, 5.0, 6.0 };
        float loopT = loops[int(h.x * 3.999)] * mix(1.4, 1.0, depth);
        loopT = 86400.0 / round(86400.0 / loopT);             // keep it a divisor of the day
        float pulseT = pulses[int(h.y * 3.999)];
        float n = round(loopT / pulseT);
        pulseT = loopT / n;
        float c = fract(t / loopT + h.z) * n;                 // pulse cycles into this climb
        float fc = fract(c);
        // contraction in the first 30% of each cycle, then a slow glide
        float pulse = smoothstep(0.0, 0.12, fc) * (1.0 - smoothstep(0.12, 0.45, fc));
        float ease = 1.0 - pow(1.0 - saturate(fc / 0.55), 3.0);
        float climb = (floor(c) + ease) / n;                  // 0..1 over the loop
        float span = 1.0 + 7.0 * r;                           // enter below, leave above, tentacles and all
        float cy = -5.0 * r + climb * span;
        float drift = sin(TAU * (t / loopT + h.w)) * 0.06 + sin(TAU * (t / loopT * 2.0 + h.z)) * 0.02;
        // spread across the display: golden-ratio strata, jittered within each
        float slot = fract(float(j) * 0.618034 + fract(seed * 0.37));
        float cx = (0.07 + 0.86 * (slot + (h.w - 0.5) * 0.08)) * aspect + drift;
        float tilt = 0.25 * cos(TAU * (t / loopT + h.w)) * 0.5 + (h.y - 0.5) * 0.3;

        float2 d = q - float2(cx, cy);
        // cheap bounds before any real work
        if (d.x < -2.2 * r || d.x > 2.2 * r || d.y < -5.2 * r || d.y > 1.6 * r) continue;
        float cs = cos(tilt), sn = sin(tilt);
        float2 p = float2(cs * d.x + sn * d.y, -sn * d.x + cs * d.y) / r;
        float core = 0.0;
        float L = jelly(p, px / r, pulse, t + h.z * 40.0, fj, core);
        float3 tint = jellyTint(fract((float(j) * 3.0 + floor(seed * 5.0)) / 5.0 + 0.02));
        // far jellies are dimmer and sink into the blue
        float3 tintD = mix(float3(0.10, 0.45, 0.70), tint, mix(0.35, 1.0, depth));
        float bright = mix(0.35, 1.1, depth) * glowBoost * (1.0 + 0.5 * pulse);
        col += (tintD * L + mix(tintD, float3(1.0), 0.6) * core) * bright;
    }

    // ---- near snow drifts in front of everything
    col += snowLayer(q, 0.090, 16.0, 0.22, 0.0026, 0.22, t, px, seed + 3.0);

    // vignette: the dark closes in at the edges
    float2 vc = (q - float2(aspect * 0.5, 0.55)) / float2(aspect, 1.0);
    col *= 1.0 - 0.55 * dot(vc, vc);

    // present(): tone map, sRGB encode, dither by half a step of the 8-bit output
    col = select(col, float3(0.0), isnan(col));
    float3 s = abyssSrgbEncode(abyssTonemap(col));
    float dn = fract(52.9829189 * fract(dot(floor(fragCoord), float2(0.06711056, 0.00583715)))) - 0.5;
    s = saturate(s + dn / 255.0);
    fragColor = vec4(s, 1.0);
}
