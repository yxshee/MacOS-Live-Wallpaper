//! title: Rain City
//! order: 8
//! bloom: 0.16
//! tags: Neon
//
// "Rain City": a cyberpunk skyline at night in the rain.
//   • a low cloud deck, lit pink and teal from below by the city, drifting slowly
//   • two searchlights sweeping up into the clouds
//   • five layers of towers receding into rain haze: lit windows (a few switch on and
//     off over time), setbacks, antennas with blinking red beacons, vertical neon signs
//     with glyphs (a couple of them faulty and flickering)
//   • flying cars crossing between the layers
//   • slanted rain in three depths, lit by whatever is behind it
//   bake – rgb: seamlessly tiling fBm (clouds).
// Everything is laid out per display (units of display height, y up).
// Motion uses the scene clock (U.target.z); every period divides a day evenly.
//
// Rain City, Copyright (c) 2026 Ilia Reingold, from https://github.com/ilrein/shaderdesk
// (Scenes/RainCity.metal), released under the MIT License (see LICENSE next to this file).
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the original:
//   - The ShaderDesk wrapper is gone: scene_frame/scene_bake, Uniforms, Galaxy, Flare, the HDR
//     "present" call and the shared bloom pass. The picture is written by mainImage() as a
//     display-ready colour, using the original's own tone map, 1 - exp(-1.15 x), and the sRGB
//     curve from ShaderDesk's Common.metal. Per-display layout becomes the whole drawn frame:
//     q = fragCoord / iResolution.y, which is the original's "display heights, y up".
//   - The baked cloud noise (scene_bake, "bg") is the image clouds.png (iChannel0), generated
//     with the same pfbm() code on a 24 x 16 cell tile. Only its R and G channels are ever read.
//     The sampler is the prelude's texture() (mip level 0) with repeat addressing.
//   - The scene clock is iTime. The shared hash11/hash12 helpers from Common.metal are copied
//     in below with the notice of their author (David Hoskins, MIT).
//   - Global constants become #defines / struct fields; pow(x, 2.0) becomes x * x (the base can
//     be negative, where pow is NaN on the GPU); the bloom pass (strength 0.16) is not
//     reproduced, so glows are the scene's own analytic ones.
//   - Slower: the faulty neon signs stuttered at 12 Hz, now 3 Hz (floor(t * 3.0)). The rain,
//     searchlights, cars, beacons and cloud drift already move at desktop pace and are unchanged.
//   - Nothing else: layout, constants, colours and every other formula are the original's.

// Hash without Sine, https://www.shadertoy.com/view/4djSRW
// MIT License...
/* Copyright (c)2014 David Hoskins.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.*/
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

// ShaderDesk's tone map and sRGB encode (Scenes/Common.metal), used in place of its present().
float3 lwTonemap(float3 x) { return 1.0 - exp(-x * 1.15); }

float3 lwSrgbEncode(float3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

#define PINK float3(1.00, 0.10, 0.55)
#define CYAN float3(0.05, 0.85, 1.00)

#define LAYERS 5
//                                 far ........................ near
float LW[5]    = { 0.030, 0.045, 0.065, 0.095, 0.150 };   // cell width
float LG[5]    = { 0.30,  0.22,  0.12,  0.00, -0.12 };    // ground line
float LHMIN[5] = { 0.06,  0.10,  0.16,  0.22,  0.20 };
float LHMAX[5] = { 0.22,  0.30,  0.40,  0.50,  0.52 };
float LTOW[5]  = { 0.12,  0.16,  0.20,  0.22,  0.20 };    // extra for towers
float LWS[5]   = { 0.0022, 0.0028, 0.0036, 0.0046, 0.0062 }; // window cell
float LFOG[5]  = { 0.74,  0.56,  0.36,  0.18,  0.04 };

// city-glow haze colour at height y: pink-magenta near the streets, teal-dark higher up
float3 fogAt(float y) {
    float3 lo = float3(0.085, 0.012, 0.070);
    float3 mid = float3(0.028, 0.008, 0.042);
    float3 hi = float3(0.005, 0.011, 0.018);
    return mix(mix(lo, mid, smoothstep(-0.05, 0.30, y)), hi, smoothstep(0.30, 0.90, y));
}

float3 neonColor(float h) {
    if (h < 0.34) return PINK;
    if (h < 0.60) return CYAN;
    if (h < 0.80) return float3(0.65, 0.20, 1.00);   // violet
    if (h < 0.92) return float3(1.00, 0.55, 0.12);   // amber
    return float3(0.30, 1.00, 0.55);                 // acid green
}

struct Hit { float a; float3 c; };

Hit layerAt(float2 q, int L, float t, float px) {
    Hit o; o.a = 0.0; o.c = float3(0.0);
    float w = LW[L];
    float fL = float(L);
    float xs = q.x / w + fL * 17.31;
    float id = floor(xs);
    float fx = fract(xs);
    float2 key = float2(id, fL * 7.13);
    float h1 = hash12(key), h2 = hash12(key + 3.3), h3 = hash12(key + 5.7);
    float h4 = hash12(key + 9.1), h5 = hash12(key + 11.9), h6 = hash12(key + 13.7);
    float h7 = hash12(key + 17.3), h8 = hash12(key + 19.1), h9 = hash12(key + 23.9);

    float bw = mix(0.70, 0.97, h2);                  // building width (cell units)
    float x0 = (1.0 - bw) * h3;
    float hgt = LG[L] + mix(LHMIN[L], LHMAX[L], h1 * h1);
    if (h4 > 0.88) hgt += LTOW[L] * (0.6 + 0.4 * h5);
    bool setback = h5 > 0.5;
    float sh = setback ? mix(0.03, 0.08, h6) * (LHMAX[L] / 0.5) : 0.0;
    float top = hgt - sh;                            // main block top

    float pc = px / w;                               // one pixel in cell units
    float y = q.y;
    float ax = smoothstep(x0 - pc * 0.5, x0 + pc * 0.5, fx) * smoothstep(x0 + bw + pc * 0.5, x0 + bw - pc * 0.5, fx);
    float body = ax * smoothstep(top + px * 0.5, top - px * 0.5, y);
    float ux0 = x0 + bw * 0.22, ux1 = x0 + bw * 0.78;
    float axU = smoothstep(ux0 - pc * 0.5, ux0 + pc * 0.5, fx) * smoothstep(ux1 + pc * 0.5, ux1 - pc * 0.5, fx);
    float upper = setback ? axU * smoothstep(hgt + px * 0.5, hgt - px * 0.5, y) : 0.0;
    float mask = max(body, upper);

    // antenna + beacon
    float ant = 0.0, beacon = 0.0;
    if (h6 > 0.45 && L < 4) {
        float ah = mix(0.02, 0.07, h7) * (LHMAX[L] / 0.5);
        float acx = (x0 + bw * 0.5) * w;                          // display units within cell
        float dx = abs(fx * w - acx);
        float aw = max(px * 0.6, 0.0006 * (1.0 + fL * 0.3));
        ant = smoothstep(aw + px * 0.5, aw - px * 0.5, dx) * step(hgt, y) * smoothstep(hgt + ah + px, hgt + ah - px, y);
        // blinking red beacon: 2 s period, per-building phase
        float ph = fract(t * 0.5 + h8);
        float on = smoothstep(0.0, 0.05, ph) * smoothstep(0.35, 0.2, ph);
        float br = length(float2(dx, y - (hgt + ah))) / max(px * 1.5, 0.0012 + fL * 0.0003);
        beacon = on * exp(-br * br) * 5.0;
    }
    mask = max(mask, ant);

    float3 c = float3(0.0025, 0.0025, 0.006);
    // street-glow bounce climbing the facade, and a thin cold rim on the left edge
    c += fogAt(y) * 0.04 * exp(-max(y - LG[L], 0.0) * 6.0);
    float lx = (fx - x0) * w;                                       // display units from left edge
    c += CYAN * 0.06 * exp(-lx / (px * 1.5 + 0.0006 * fL)) * body;

    // windows
    float ws = LWS[L];
    float2 wc = float2(lx / ws, (y - LG[L]) / (ws * 1.6));
    float2 cid = floor(wc);
    float2 f = fract(wc);
    float bwD = bw * w;
    bool inFacade = lx > ws * 0.6 && lx < bwD - ws * 0.6 && y < top - ws * 2.0;
    if (inFacade && body > 0.0) {
        float2 wk = cid + float2(id * 13.1, fL * 91.7);
        float litP = mix(0.05, 0.42, h7 * h7);
        float wh = hash12(wk);
        // ~12% of windows re-roll every 45 s (staggered), so the city slowly lives
        if (hash12(wk + 4.4) < 0.12) wh = hash12(wk + floor(t / 45.0 + hash12(wk + 8.8)));
        // whole floors lit in some buildings
        if (h9 > 0.8 && hash12(float2(cid.y, id) + 2.2) < 0.25) wh *= 0.2;
        float lit = step(wh, litP);
        float fwx = px / ws, fwy = px / (ws * 1.6);
        float rx = smoothstep(0.18 - fwx, 0.18 + fwx, f.x) * smoothstep(0.82 + fwx, 0.82 - fwx, f.x);
        float ry = smoothstep(0.22 - fwy, 0.22 + fwy, f.y) * smoothstep(0.72 + fwy, 0.72 - fwy, f.y);
        float cov = mix(rx * ry, 0.32, saturate(fwx * 1.6 - 0.35));   // filter when tiny
        float3 wcol = h8 < 0.45 ? float3(1.0, 0.70, 0.42)              // warm
                    : h8 < 0.80 ? float3(0.55, 0.82, 1.0)             // office cool
                                : mix(PINK, float3(0.8, 0.6, 1.0), 0.4);
        wcol *= mix(0.45, 1.3, hash12(wk + 1.7));
        c += wcol * lit * cov * 0.9;
    }

    // vertical neon sign on nearer buildings
    if (L >= 2 && h9 < 0.42) {
        float sw = ws * 2.6;
        float shh = mix(0.07, 0.20, hash12(key + 29.3)) * (LHMAX[L] / 0.55);
        float sxc = (h3 < 0.5 ? x0 + bw * 0.2 : x0 + bw * 0.8) * w;
        float syc = top - shh * 0.5 - ws * 3.0;
        float2 sp = float2(fx * w - sxc, y - syc);
        float2 hs = float2(sw * 0.5, shh * 0.5);
        float2 e = abs(sp) - hs;
        float sd = max(e.x, e.y);
        if (sd < px && syc - hs.y > LG[L] + 0.02) {
            float3 nc = neonColor(hash12(key + 31.1));
            // faulty signs stutter; the rest hum steadily with a slow breathing
            float on = 1.0;
            float bad = hash12(key + 37.7);
            if (bad < 0.25) {
                float k = floor(t * 3.0);     // original: floor(t * 12.0), slowed for a desktop
                on = hash12(float2(k, id)) < mix(0.02, 0.35, step(0.8, hash12(float2(floor(t / 3.0), id)))) ? 0.08 : 1.0;
            }
            on *= 0.85 + 0.15 * sin(t * 6.2831853 / 4.0 + bad * 6.2831853);
            float inside = smoothstep(px, -px, sd);
            float bt = max(sw * 0.07, px * 1.2);
            float border = smoothstep(bt + px, bt - px, abs(sd + bt * 1.2));
            // glyphs: stacked 3x4 block characters
            float gs = sw * 0.62;
            float2 gp = float2((sp.x + gs * 0.5) / gs, (sp.y + hs.y - sw * 0.3) / (gs * 1.35));
            float2 gi = floor(gp);
            float2 gf = fract(gp);
            float2 bi = floor(float2(gf.x * 3.0, gf.y * 4.0));
            float2 bf = fract(float2(gf.x * 3.0, gf.y * 4.0));
            float glyph = step(hash12(gi * 7.7 + bi * 1.3 + key), 0.52);
            glyph *= step(0.0, gp.x) * step(gp.x, 1.0) * step(0.0, gp.y) * step(gp.y, floor(shh / (gs * 1.35) - 0.3));
            glyph *= step(gf.y, 0.82);
            float fb = px / (gs / 3.0);
            glyph *= mix(smoothstep(0.08, 0.08 + fb, bf.x) * smoothstep(0.92, 0.92 - fb, bf.x) *
                         smoothstep(0.08, 0.08 + fb, bf.y) * smoothstep(0.92, 0.92 - fb, bf.y), 0.7, saturate(fb * 2.0 - 0.3));
            float3 sc = float3(0.02, 0.01, 0.03) + nc * 0.08;
            sc += nc * (border * 3.2 + glyph * 2.4) * on;
            c = mix(c, sc, inside);
        }
    }
    c += float3(1.0, 0.08, 0.05) * beacon;
    o.a = max(mask, saturate(beacon));
    o.c = c;
    return o;
}

// one depth of rain streaks: returns streak intensity
float rainLayer(float2 q, float t, float scale, float speed, float seed, float px, float thick) {
    float2 p = q;
    p.x += p.y * 0.14;                               // wind slant
    p *= scale;
    float col = floor(p.x);
    float fx = fract(p.x) - 0.5;
    float h = hash12(float2(col, seed));
    float v = p.y * 0.09 + t * speed + h * 7.0;
    float seg = floor(v);
    float f = fract(v);
    float present = step(hash12(float2(col, seg) + seed), 0.45);
    float xo = (hash12(float2(seg, col) + seed * 1.3) - 0.5) * 0.6;
    float wdt = max(thick, px * scale * 0.7);
    float ux = (fx - xo) / wdt;
    float across = exp(-(ux * ux)) * min(1.0, thick / wdt * 1.5);
    float along = smoothstep(0.0, 0.03, f) * smoothstep(0.34, 0.03, f);
    return present * across * along;
}

void mainImage(thread vec4& fragColor, vec2 fragCoord) {
    float t = iTime;
    float aspect = iResolution.x / iResolution.y;
    float2 q = fragCoord / iResolution.y;                    // display heights, y up
    float cx = aspect * 0.5;
    float px = 1.0 / iResolution.y;

    // ---- sky: city glow under a low cloud deck
    float3 col = fogAt(q.y) * 0.9;
    col = mix(col, float3(0.006, 0.008, 0.018), smoothstep(0.5, 1.0, q.y));
    {
        float2 cu = float2(q.x / aspect * 0.32 + t / 2400.0, q.y * 0.42);
        float3 n = texture(iChannel0, cu).rgb;
        float n2 = texture(iChannel0, cu * 2.1 + float2(t / 1600.0, 0.3)).g;
        float dens = n.r * 0.7 + n2 * 0.3;
        float d = smoothstep(0.30, 0.70, dens) * smoothstep(0.40, 0.75, q.y);
        // underside lit by the city: brightest on the lower cloud edges, fading upward
        float under = exp(-max(q.y - 0.48, 0.0) * 4.5) * (1.0 - smoothstep(0.45, 0.8, dens) * 0.6);
        float3 lit = mix(float3(0.17, 0.022, 0.13), float3(0.03, 0.075, 0.10), smoothstep(0.55, 0.8, n.g) * 0.6);
        float3 cc = float3(0.004, 0.004, 0.010) + lit * under;
        col = mix(col, cc, d * 0.9);
    }

    // ---- searchlights sweeping into the clouds
    for (int i = 0; i < 2; i++) {
        float fi = float(i);
        float2 o = float2(cx + (fi == 0.0 ? -0.42 : 0.55) * aspect * 0.5, 0.18);
        float a = 1.5708 + (fi == 0.0 ? 0.30 : -0.25) + 0.28 * sin(t * 6.2831853 / (fi == 0.0 ? 60.0 : 90.0) + fi * 2.0);
        float2 dir = float2(cos(a), sin(a));
        float2 r = q - o;
        float al = dot(r, dir);
        float pd = abs(r.x * dir.y - r.y * dir.x);
        float wdt = 0.003 + al * 0.035;
        float beam = exp(-pd * pd / (wdt * wdt)) * smoothstep(0.0, 0.08, al) * exp(-al * 1.4);
        col += float3(0.55, 0.80, 1.0) * beam * 0.16;
    }

    // ---- building layers, composited front to back (near → far) so a pixel stops as
    // soon as it's covered; flying cars sit between layers 2 and 3
    float3 acc = float3(0.0);
    float T = 1.0;
    for (int L = LAYERS - 1; L >= 0; L--) {
        // rain haze drifting in front of this layer, brightest at street level
        if (L < LAYERS - 1) acc += T * fogAt(q.y) * 0.03 * exp(-max(q.y - LG[L], 0.0) * 7.0);
        if (L == 2) {
            for (int k = 0; k < 4; k++) {
                float fk = float(k);
                float P = (k == 0 ? 72.0 : k == 1 ? 90.0 : k == 2 ? 120.0 : 144.0);
                float dirS = (k % 2 == 0) ? 1.0 : -1.0;
                float span = aspect + 0.4;
                float ph = fract(t / P + hash11(fk * 3.7));
                float x = dirS > 0.0 ? ph * span - 0.2 : aspect + 0.2 - ph * span;
                float y = 0.40 + fk * 0.075 + 0.004 * sin(t * 6.2831853 / 8.0 + fk);
                float2 d = q - float2(x, y);
                if (abs(d.y) > 0.01 || abs(d.x) > 0.07) continue;
                float sz = 0.0022;
                float2 dh = d - float2(dirS * sz, 0.0), dt = d + float2(dirS * sz, 0.0);
                float head = exp(-dot(dh, dh) / (sz * sz * 0.35));
                float tail = exp(-dot(dt, dt) / (sz * sz * 0.35));
                float cy = d.y / (sz * 0.35);
                float trail = exp(-(cy * cy)) * saturate(1.0 + d.x * dirS / 0.05) * step(0.0, -d.x * dirS);
                acc += T * (float3(0.8, 0.95, 1.0) * head * 5.0 + float3(1.0, 0.1, 0.12) * (tail * 3.0 + trail * 0.25));
            }
        }
        if (q.y > LG[L] + LHMAX[L] + LTOW[L] + 0.08) continue;
        Hit h = layerAt(q, L, t, px);
        float3 bc = mix(h.c, fogAt(q.y), LFOG[L]);
        acc += T * h.a * bc;
        T *= 1.0 - h.a;
        if (T < 0.002) break;
    }
    col = acc + T * col;

    // ---- rain, lit by what's behind it
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float3 rc = mix(float3(0.55, 0.65, 0.8), col / max(lum, 1e-3) * 0.6, 0.5);
    float r = rainLayer(q, t, 60.0, 1.9, 1.0, px, 0.030) * 0.55
            + rainLayer(q, t, 110.0, 1.5, 2.0, px, 0.045) * 0.40
            + rainLayer(q, t, 200.0, 1.2, 3.0, px, 0.06) * 0.28;
    col += rc * r * (0.035 + lum * 0.9);
    // overall wet haze
    col += fogAt(q.y) * 0.008;

    float2 vc = (q - float2(cx, 0.5)) / float2(aspect, 1.0);
    col *= 1.0 - 0.45 * dot(vc, vc);
    fragColor = vec4(lwSrgbEncode(lwTonemap(col)), 1.0);
}
