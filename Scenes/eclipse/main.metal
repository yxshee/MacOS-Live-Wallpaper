//! title: Eclipse
//! order: 2
//! bloom: 0.06
//! tags: Stars
//
// "Eclipse": a total solar eclipse over a dark ridge line, one sun per display.
//   bake  – rgb: three channels of seamlessly tiling fBm; a: a sparse starfield.
//   frame – • the corona: pearly white, falling off steeply from the limb, with fine
//             radial rays that bend toward the equator the way the field lines do,
//             big helmet streamers that taper to points, polar plumes over dim holes
//           • the pink chromosphere and prominences at the edge of the Moon
//           • the Moon itself, faintly lit by earthshine, with darker maria
//           • the Moon rocks slowly along its path (a stylised, seamless loop). At each
//             end of the swing its rough limb uncovers the Sun: first Baily's beads
//             through the valleys, then the diamond ring, with a glare that briefly
//             lights up the sky and drowns the corona
//           • a deep twilight sky with the 360° sunset glow along the horizon, Venus,
//             a few stars, and two layers of mountain silhouettes
// Motion uses the scene clock (U.target.z); every period divides a day evenly.
//
// "Eclipse" is Scenes/Eclipse.metal from Shaderdesk, https://github.com/ilrein/shaderdesk
// Copyright (c) 2026 Ilia Reingold. MIT License (see the LICENSE file beside this one).
// Its hash functions (hash11, hash12, hash22), carried in Shaderdesk's Scenes/Common.metal,
// are David Hoskins' "Hash without Sine", https://www.shadertoy.com/view/4djSRW:
// Copyright (c)2014 David Hoskins. MIT License (see LICENSE).
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the original:
//   - The Shaderdesk wrapper is gone: scene_frame/scene_bake, the Uniforms/Galaxy/Flare
//     buffers and the agent-activity inputs are replaced by mainImage(). The pieces of
//     Scenes/Common.metal the scene uses (hash11/12/22, vnoise, noise1, fbm1, the
//     star layer, tone map, sRGB encode) are copied in below; the rest is not needed.
//   - scene_bake's three tiling fBm channels (pfbm, 5 octaves, 24 x 14 cells) come from
//     noise.png, an image generated with a C transcription of that exact bake. Its
//     starfield alpha is computed per pixel instead (same starLayer calls). The
//     texture is read at a mip level chosen from how many texels a pixel covers, so
//     the fine rays stay smooth when the picture is drawn at a low resolution.
//   - Shaderdesk's post pass (bloom at 0.06, tone map, sRGB, dither) is replaced by the
//     same tone map and sRGB encode at the end of mainImage; the bloom is not
//     reproduced (the app dithers the result itself).
//   - "points" (U.display, U.view.z) became a virtual 1080-point screen height, so
//     the stars, mountains and glare spikes keep their size relative to the picture at
//     any resolution. The sun still sits at 0.58 / 0.56 of the width / height.
//   - The scene clock is iTime wrapped at one day; the star twinkle uses it too.
//   - GLSL-isms for our wrapper: constants are #defines, the SunFrame struct and the
//     inline/constant qualifiers are gone, output parameters are thread references.
// The look, the timing and every constant of the picture are the author's.

#define EPI 3.14159265
#define MOON_K 1.032      // Moon radius / Sun radius
#define SWING_T 360.0     // seconds per full rock of the Moon (two diamond rings)
#define SWING_A 0.046     // quick excursion at each end of the rock (sun radii)
#define DRIFT_A 0.012     // slow part of the rock (sun radii)
#define EQ 0.38           // tilt of the solar equator (radians)
#define REF_H 1080.0      // virtual points per screen height

// ---- from Shaderdesk's Common.metal --------------------------------------------------------
// hash11, hash12, hash22: Hash without Sine, Copyright (c)2014 David Hoskins, MIT License.
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

float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash12(i), hash12(i + vec2(1, 0)), u.x),
               mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), u.x), u.y);
}

float noise1(float x) {
    float i = floor(x), f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(hash11(i), hash11(i + 1.0), u);
}

float fbm1(float x, int octaves) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < octaves; i++) {
        s += a * noise1(x);
        x = x * 2.07 + 13.1;
        a *= 0.5;
    }
    return s;
}

// One layer of randomly placed stars on a jittered grid (cell size in points).
// Returns the summed intensity (the original's colour output was never used by this scene).
float starLayer(vec2 pt, float cell, float prob, float bMin, float bMax, float bPow,
                float sizePt, float minSigma, float seed, float spikes) {
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
            float I = b * exp(-dot(d, d) / (2.0 * sigma * sigma));
            if (spikes > 0.0 && b > bMax * 0.35) {
                float k = 1.0 / sigma;
                vec2 ad = abs(d) * k;
                float s = exp(-ad.x * 1.4) * exp(-ad.y * 0.13) + exp(-ad.y * 1.4) * exp(-ad.x * 0.13);
                I += b * 0.10 * spikes * s;
                // soft photographic halo, like light scattering in the optics
                I += b * 0.045 * spikes * exp(-length(d) * k * 0.22);
            }
            total += I;
        }
    }
    return total;
}

// soft filmic curve that keeps the darks dark but not crushed
vec3 tonemap(vec3 x) {
    return 1.0 - exp(-x * 1.15);
}

vec3 srgbEncode(vec3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, c <= 0.0031308);
}

// ---- the scene -------------------------------------------------------------------------------
float Rpx;       // sun radius in pixels
float pxPerPt;   // pixels per virtual point

// The baked noise (noise.png) at a mip level that matches how many of its texels one pixel covers.
vec4 nz(vec2 uv, float texelsPerPixel) {
    return iChannel0.sample(lwRepeat, uv, level(log2(max(texelsPerPixel, 1.0))));
}

// Texels per pixel for a lookup whose x runs `ka` times round the Sun and whose y moves `kr` per sun radius.
float tpp(float ka, float kr, float r) {
    return max(ka * iChannelResolution[0].x / (6.2831853 * max(r, 0.5)), kr * iChannelResolution[0].y) / Rpx;
}

// Moon centre relative to the Sun (sun radii). A slow sinusoidal drift, plus a sharp
// |s|^41 excursion at each end: long totality, then ~10 s of beads and diamond ring.
vec2 moonOffset(float t, thread vec2& dir) {
    dir = normalize(vec2(1.0, 0.32));
    float s = sin(2.0 * EPI * (t - 47.0) / SWING_T);
    return dir * (DRIFT_A * s + SWING_A * sign(s) * pow(abs(s), 41.0));
}

// lunar limb: radius as a function of angle; mountains and valleys a few ‰ high.
// The angle's seam sits 90° from the contact points, where it's always covered.
float moonLimb(float phi) {
    float x = phi * 45.0 + 40.0;
    return MOON_K + 0.008 * (fbm1(x, 3) - 0.44);
}

float wrapAngle(float a) { return atan2(sin(a), cos(a)); }

void mainImage(thread vec4& fragColor, vec2 fragCoord)
{
    float t = mod(iTime, 86400.0);
    pxPerPt = iResolution.y / REF_H;
    Rpx = iResolution.y * 0.19;                                  // S.R = display height * 0.19
    vec2 sunC = vec2(iResolution.x * 0.58, iResolution.y * 0.56);
    float pxR = Rpx;                                             // pixels per sun radius
    float Rpt = Rpx / pxPerPt;                                   // sun radius in points
    vec2 pt = fragCoord / pxPerPt;                               // virtual points, y up

    vec2 q = (fragCoord - sunC) / Rpx;
    float r = length(q);
    float a = atan2(q.y, q.x);
    float d = max(r - 1.0, 0.0);

    // ---- Moon and how much Sun it lets through --------------------------------
    vec2 dir = vec2(0.0);
    vec2 mo = moonOffset(t, dir);
    vec2 perp = vec2(-dir.y, dir.x);
    vec2 qm = q - mo;
    float rm = length(qm);
    float Rm = moonLimb(atan2(dot(qm, dir), dot(qm, perp)));
    float moonCover = saturate(0.5 - (rm - Rm) * pxR);

    // diamond-ring strength from the deepest uncovered sliver at the contact point
    float mol = length(mo);
    vec2 cdir = mol > 1e-5 ? -mo / mol : -dir;
    vec2 cp = cdir;                                             // contact point on the limb
    float cphi = atan2(dot(cp - mo, dir), dot(cp - mo, perp));
    float depth = length(cp - mo) - moonLimb(cphi);             // >0: sunlight gets through
    float E = smoothstep(0.0, 0.016, depth);
    float E2 = E * E;

    // ---- sky ----------------------------------------------------------------------
    float h = pt.y / REF_H;                                     // 0 at the bottom, 1 top
    vec3 col = mix(vec3(0.010, 0.010, 0.022), vec3(0.0020, 0.0032, 0.0090), smoothstep(0.0, 0.9, h));
    col += vec3(0.70, 0.30, 0.080) * exp(-h * 14.0) * 0.16;     // sunset glow all around
    col += vec3(0.60, 0.18, 0.060) * exp(-h * 6.0) * 0.04;
    col += vec3(0.30, 0.10, 0.120) * exp(-h * 4.0) * 0.020;
    col += vec3(0.50, 0.58, 0.80) * exp(-d * 0.55) * 0.010;     // scattered coronal light
    col *= 1.0 + 1.6 * E2;                                      // the sky brightens at the ring
    col += vec3(0.20, 0.30, 0.55) * E2 * 0.02 * smoothstep(0.1, 1.0, h);

    // stars and Venus, lost in the glare near the Sun and at the diamond ring
    float starA = smoothstep(1.6, 4.5, r) * (1.0 - 0.9 * E) * smoothstep(0.08, 0.3, h);
    if (starA > 0.0) {
        float minSigma = 0.55 / pxPerPt;
        float stars = starLayer(pt, 26.0, 0.22, 0.02, 0.18, 4.0, 0.50, minSigma, 3.0, 0.0);
        stars += starLayer(pt, 120.0, 0.30, 0.20, 1.2, 4.0, 0.70, minSigma, 9.0, 1.0);
        starA *= stars;
        if (starA > 0.004) {
            float tw = vnoise(pt * 0.09 + vec2(t * 0.4, -t * 0.27));
            starA *= 1.0 - 0.3 * (1.0 - tw);
        }
        col += vec3(0.92, 0.94, 1.0) * starA;
    }
    {
        float minVar = 2.0 * (0.55 / pxPerPt) * (0.55 / pxPerPt);   // keep the planets at least a pixel wide
        vec2 dv = (q - vec2(-3.6, -0.9)) * Rpt;                 // points
        float vr2 = dot(dv, dv);
        col += vec3(1.0, 0.96, 0.88) * (3.0 * exp(-vr2 / max(1.6, minVar)) + 0.03 * exp(-sqrt(vr2) * 0.22)) * (1.0 - 0.6 * E);
        vec2 dj = (q - vec2(3.3, 1.35)) * Rpt;
        col += vec3(1.0, 0.93, 0.82) * (0.9 * exp(-dot(dj, dj) / max(1.2, minVar))) * (1.0 - 0.8 * E);
    }

    // ---- corona -------------------------------------------------------------------
    if (r > 0.99) {
        float da = a - EQ;
        float eqness = abs(cos(da));
        // follow a ray back to its footpoint: mid-latitude field lines lean equatorward
        float a0 = a + 0.30 * sin(2.0 * da) * (1.0 - 1.0 / r);
        float u = a0 / (2.0 * EPI);
        float lr = log(r);
        // three octaves of hair-fine rays, streaming outward (integer angular
        // frequencies so the texture wraps round the circle; every rate * 86400 is whole)
        float f0 = nz(vec2(u * 3.0, lr * 0.05 - t / 2400.0), tpp(3.0, 0.05 / r, r)).b;
        float f1 = nz(vec2(u * 9.0 + 0.17, lr * 0.14 - t * 0.00125), tpp(9.0, 0.14 / r, r)).r;
        float f2 = nz(vec2(u * 20.0 + 0.31, lr * 0.22 - t * 0.0025), tpp(20.0, 0.22 / r, r)).g;
        float f3 = nz(vec2(u * 34.0 + 0.63, lr * 0.30 - t * 0.0025), tpp(34.0, 0.30 / r, r)).b;
        float fineIn = smoothstep(1.02, 1.5, r);
        float rays = 0.30 + 0.9 * pow(smoothstep(0.30, 0.80, f0), 2.0)
                          + 1.1 * pow(smoothstep(0.32, 0.80, f1), 2.0)
                          + 0.8 * pow(smoothstep(0.36, 0.84, f2), 2.0)
                          + 0.6 * pow(smoothstep(0.40, 0.86, f3), 2.0) * (0.4 + 0.6 * fineIn);

        // helmet streamers: bulbous at the base, narrowing to long stalks
        float st = 0.0;
        for (int i = 0; i < 5; i++) {
            float th = EQ + ((i == 0) ? 0.06 : (i == 1) ? EPI - 0.12 : (i == 2) ? 0.62 : (i == 3) ? EPI + 0.55 : -0.72);
            float w  = (i == 0) ? 0.24 : (i == 1) ? 0.27 : (i == 2) ? 0.13 : (i == 3) ? 0.16 : 0.10;
            float bi = (i == 0) ? 1.00 : (i == 1) ? 0.85 : (i == 2) ? 0.55 : (i == 3) ? 0.50 : 0.40;
            th += 0.05 * sin(t * (2.0 * EPI / 1800.0) + float(i) * 2.1);  // slow sway
            float dd = wrapAngle(a0 - th);
            float wr = w * (0.30 + 0.70 * exp(-d * 1.2));
            st += bi * exp(-dd * dd / (wr * wr));
        }

        float holes = mix(0.22, 1.0, smoothstep(0.15, 0.80, eqness));
        float plumes = pow(smoothstep(0.50, 0.85, f2), 3.0) * pow(1.0 - eqness, 2.0);

        float I = 0.0;
        I += 1.30 * pow(r, -7.0) * holes * (0.45 + 0.55 * rays);      // bright inner K-corona
        I += 0.45 * exp(-d * 18.0);                                   // the ring right at the limb
        I += 0.09 * pow(r, -2.4) * holes * rays;                     // extended rays
        I += st * 1.00 * pow(r, -2.6) * (0.35 + 0.75 * rays);        // streamers
        I += plumes * 1.3 * pow(r, -3.6);                            // polar plumes
        // colour: gold at the limb, pearl in the middle, cold violet-blue far out
        vec3 cc = mix(vec3(1.00, 0.74, 0.42), vec3(1.00, 0.93, 0.86), smoothstep(0.0, 0.30, d));
        cc = mix(cc, vec3(0.55, 0.68, 1.00), smoothstep(0.35, 1.8, d));
        cc = mix(cc, vec3(0.62, 0.45, 1.00), smoothstep(1.6, 4.0, d) * 0.7);
        col += cc * I * (1.0 - 0.55 * E);
        // a wide scattered glow that tints the whole sky
        col += vec3(0.30, 0.38, 0.85) * exp(-d * 0.8) * 0.030 * (0.6 + 0.4 * rays) * (1.0 - 0.5 * E);

        // chromosphere: a thin pink shell of spicules
        // (stylised: thick enough to peek out past the Moon's slightly larger disc)
        float sp = nz(vec2(a / (2.0 * EPI) * 40.0, d * 2.0 - t * 0.0025), tpp(40.0, 2.0, r)).r;
        float sp2 = nz(vec2(a / (2.0 * EPI) * 13.0 + 0.4, 0.37), tpp(13.0, 0.0, r)).g;
        float shell = exp(-d / (0.012 + 0.030 * sp * sp2));
        col += vec3(1.0, 0.08, 0.26) * shell * 3.0;

        // prominences: pink loops and hedgerows standing off the limb
        if (r < 1.45) {
            for (int i = 0; i < 8; i++) {
                float P = (i == 0) ? 144.0 : (i == 1) ? 180.0 : (i == 2) ? 160.0 : (i == 3) ? 240.0 : (i == 4) ? 120.0 : (i == 5) ? 200.0 : (i == 6) ? 150.0 : 216.0;
                float tt = t + float(i) * 41.0;
                float k = floor(tt / P), f = fract(tt / P);
                vec3 hh = vec3(hash12(vec2(k, float(i) * 7.1)), hash12(vec2(k + 3.3, float(i))),
                               hash12(vec2(float(i), k * 1.7)));
                float th = hh.x * 2.0 * EPI;
                vec2 Nn = vec2(cos(th), sin(th)), T = vec2(-Nn.y, Nn.x);
                float y = dot(q, Nn) - 0.998;
                float x = dot(q, T) - y * (hh.z - 0.5) * 1.6;              // leaning arches
                float life = pow(sin(EPI * f), 2.2);
                float wdt = 0.05 + 0.10 * hh.y;
                float hgt = (0.10 + 0.22 * hh.z) * (0.6 + 0.4 * f);
                float yc = (y + 0.4 * hgt) / (1.4 * hgt);                 // arch centre below the limb
                float e = length(vec2(x / wdt, yc));
                float along = atan2(yc, x / wdt);
                float feat = max(e, 0.3) * min(wdt, hgt) * Rpx;           // size of the arch in pixels
                float fil = nz(vec2(along * 0.35 + hh.x * 5.0, t * 0.008 + hh.y), iChannelResolution[0].x * 0.35 / feat).b;
                vec3 pc;
                if (hh.y > 0.62) {
                    // loop
                    float dist = abs(e - 1.0) * min(wdt, hgt);
                    float w = (0.010 + 0.022 * fil);
                    float core = exp(-dist * dist / (w * w));
                    float strands = nz(vec2(along * 1.3 + hh.z * 3.0, e * 0.8 - t * 0.003),
                                       max(iChannelResolution[0].x * 1.3, iChannelResolution[0].y * 0.8) / feat).g;
                    float loop = core * (0.4 + 1.2 * smoothstep(0.35, 0.75, strands))
                               + exp(-dist / (w * 2.0)) * 0.14 * exp(-max(e - 1.0, 0.0) * 3.0);
                    loop *= smoothstep(-0.004, 0.012, y);
                    pc = mix(vec3(1.0, 0.03, 0.14), vec3(1.0, 0.22, 0.34), core) * loop * (0.5 + 1.2 * fil);
                } else {
                    // hedgerow: a flame-like sheet, ragged along the top
                    float fx = nz(vec2(x * 1.8 + hh.z * 7.0, y * 0.6 + t * 0.004),
                                  max(iChannelResolution[0].x * 1.8, iChannelResolution[0].y * 0.6) / Rpx).r;
                    float top = hgt * (0.55 + 0.9 * fx);
                    float body = smoothstep(wdt, wdt * 0.5, abs(x)) * smoothstep(top, top * 0.6, y) * smoothstep(-0.004, 0.006, y);
                    pc = mix(vec3(0.9, 0.02, 0.12), vec3(1.0, 0.20, 0.32), fx) * body * (0.35 + 0.9 * fil) * 0.9;
                }
                col += pc * life * 5.0 * smoothstep(1.45, 1.28, r);
            }
        }
    }

    // ---- photosphere, where the Moon's valleys let it through ------------------------
    float sunIn = saturate(0.5 + (1.0 - r) * pxR);
    if (sunIn > 0.0) {
        float z = sqrt(max(0.0, 1.0 - r * r));
        vec3 ph = vec3(1.0, 0.94, 0.84) * 60.0 * (0.35 + 0.65 * pow(z, 0.5));
        col = mix(col, ph, sunIn);
    }

    // ---- the Moon: black, with the faintest earthshine ----------------------------------
    if (moonCover > 0.0) {
        vec2 ts = iChannelResolution[0].xy;
        vec2 mq = qm / MOON_K;
        float mz = sqrt(max(0.0, 1.0 - dot(mq, mq)));
        // squash the texture toward the limb so it reads as a sphere
        vec2 muv = mq / (0.45 + 0.55 * mz);
        muv.y *= ts.x / ts.y;
        float mpx = 1.0 / (MOON_K * Rpx * (0.45 + 0.55 * max(mz, 0.15)));   // moon-uv units per pixel (limb steepening capped)
        float m1 = nz(muv * 0.11 + vec2(0.13, 0.71), 0.11 * ts.x * mpx).r;
        float m2 = nz(muv * 0.45 + vec2(0.37, 0.19), 0.45 * ts.x * mpx).g;
        float m3 = nz(muv * 1.6 + vec2(0.71, 0.53), 1.6 * ts.x * mpx).b;
        float mare = smoothstep(0.56, 0.42, m1 + (m2 - 0.5) * 0.20);
        float alb = mix(1.0, 0.55, mare) * (0.85 + 0.30 * m3);
        alb += 0.35 * pow(smoothstep(0.62, 0.80, m2), 2.0) * (1.0 - mare);   // bright highlands
        // earthshine: lit from the front, slightly from the lower left
        float lit = 0.25 + 0.75 * saturate(dot(vec3(mq, mz), normalize(vec3(-0.35, -0.25, 0.9))));
        vec3 mc = vec3(0.45, 0.55, 0.95) * 0.0055 * alb * lit;
        mc *= 1.0 + 1.0 * E2;
        col = mix(col, mc, moonCover);
    }

    // ---- mountains --------------------------------------------------------------------
    {
        float gx = pt.x;
        float far = REF_H * (0.105 + 0.070 * (fbm1(gx / 260.0 + 3.0, 6) - 0.45));
        float nearR = REF_H * (0.050 + 0.075 * (fbm1(gx / 420.0 + 11.0, 6) - 0.40));
        float aa = 1.0 / pxPerPt;
        float farC = saturate((far - pt.y) / aa + 0.5);
        float nearC = saturate((nearR - pt.y) / aa + 0.5);
        float hf = far / REF_H;
        vec3 farCol = (vec3(0.70, 0.28, 0.07) * exp(-hf * 14.0) * 0.05 + vec3(0.004, 0.005, 0.010)) * (1.0 + 5.0 * E2);
        // thin rim where the glow behind catches the far crest
        farCol += vec3(0.6, 0.25, 0.08) * 0.02 * exp(-max(far - pt.y, 0.0) * 1.2);
        col = mix(col, farCol, farC);
        vec3 nearCol = vec3(0.0012, 0.0012, 0.0018) * (1.0 + 4.0 * E2);
        col = mix(col, nearCol, nearC);
    }

    // ---- diamond-ring glare and lens ghosts (in the lens, so over everything) -------------------------------------------
    if (E > 0.0) {
        vec2 g = q - cp;
        float gd = length(g);
        vec3 gc = vec3(1.0, 0.95, 0.86);
        // the broad glare is held back over the Moon so its disc stays dark
        float onMoon = mix(1.0, 0.3, moonCover);
        float glare = 40.0 * exp(-gd * 90.0)
                    + (7.0 * exp(-gd * 20.0) + 1.2 * exp(-gd * 5.0) + 0.06 * exp(-gd * 1.4) + 0.015 * exp(-gd * 0.5)) * onMoon;
        vec2 gs = g * Rpt;                                        // points
        float spikes = exp(-abs(gs.y) * 0.9) * exp(-abs(gs.x) * 0.012) + exp(-abs(gs.x) * 0.9) * exp(-abs(gs.y) * 0.02);
        float streak = exp(-abs(g.y) * 70.0) * exp(-abs(g.x) * 2.0);
        col += gc * (glare + (spikes * 0.25 + streak * 0.12) * onMoon) * E2;

        vec2 dispC = (0.5 * iResolution.xy - sunC) / Rpx;
        for (int i = 0; i < 4; i++) {
            float kk = (i == 0) ? 0.6 : (i == 1) ? 1.4 : (i == 2) ? 2.1 : 3.2;
            float gr = (i == 0) ? 0.12 : (i == 1) ? 0.35 : (i == 2) ? 0.08 : 0.55;
            vec2 gpos = cp + (dispC - cp) * kk;
            float gdd = length(q - gpos) / gr;
            float ring = smoothstep(1.0, 0.8, gdd) * (0.3 + 0.7 * smoothstep(0.3, 1.0, gdd));
            vec3 ghc = (i == 1) ? vec3(0.25, 0.55, 0.40) : (i == 3) ? vec3(0.45, 0.30, 0.60) : vec3(0.60, 0.45, 0.25);
            col += ghc * ring * 0.05 * E2;
        }
    }

    // ---- display: the tone map and sRGB encode Shaderdesk's post pass applies ------------
    col = select(col, vec3(0.0), isnan(col));
    fragColor = vec4(srgbEncode(tonemap(col)), 1.0);
}
