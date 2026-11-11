#include <metal_stdlib>
using namespace metal;

// How a frame is made, cheapest thing first:
//
//   sky     Everything soft (gradient, sun and moon glow, Milky Way, aurora,
//           clouds) painted at a quarter of the sky's points.
//   stars   The sky layer you see, one pixel per point: the soft sky plus the
//           stars, the sun and moon discs and any shooting star.
//   ridges  A second layer on top, at full Retina resolution and transparent
//           above the skyline. It is redrawn only when it would look different
//           (a few times a minute), so the sharpest part of the picture is
//           also the part that costs almost nothing.
//
// All noise comes from one small pre-baked texture, so nothing here loops over
// octaves. Colours are held squared (close to linear light) and square-rooted
// on the way out.

#define LAYERS 6

struct Layer {
    float4 geo;     // frequency, offset, highest point, mist drift
    float4 crest;   // rgb at the crest, a = depth (0 near, 1 far)
    float4 base;    // rgb at the misted foot, a = mist amount
};

struct Uniforms {
    float4 view;        // aspect, -, -, horizon height
    float4 clock;       // seconds mod 64, cloud drift a, cloud drift b, aurora drift
    float4 zenith;      // rgb, star visibility
    float4 horizon;     // rgb
    float4 glow;        // rgb, low-sun band strength
    float4 sun;         // x, y, radius, disc strength
    float4 sunColor;    // rgb
    float4 moon;        // x, y, radius, visibility
    float4 moonLight;   // light direction xyz, glow strength
    float4 starRot;     // cos, sin, pole x, pole y
    float4 milky;       // arch centre x, y (star space), arch radius, strength
    float4 aurora;      // strength, seed
    float4 cloud;       // cover, light x, light y, opacity
    float4 cloudLit;    // rgb
    float4 cloudShade;  // rgb
    float4 meteorA;     // head xy, tail xy
    float4 meteorB;     // intensity
    float4 cabin;       // x, y, intensity
    float4 nebula;      // three drift angles, star visibility
    Layer layers[LAYERS];
};

// The strip of the scene a pass covers, and how finely.
struct Pass {
    float4 r;           // scene height at the bottom, at the top, px per scene height, px per point
};

struct VOut { float4 pos [[position]]; float2 uv; };

constexpr sampler tile(filter::linear, address::repeat);
constexpr sampler edge(filter::linear, address::clamp_to_edge);
constexpr sampler ridgeSampler(filter::linear, s_address::repeat, t_address::clamp_to_edge);

vertex VOut fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;                       // (0,0) is the bottom-left corner
    return o;
}

// Scene coordinates: x across (zero in the middle, in screen heights), y from 0 at the bottom to 1 at the top.
static inline float2 scenePoint(VOut in, float aspect, float4 r) {
    return float2((in.uv.x - 0.5) * aspect, mix(r.x, r.y, in.uv.y));
}

static inline float3 hash32(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}

static inline float2 starSpace(float2 w, float4 rot) {
    float2 r = w - rot.zw;
    return float2(r.x * rot.x - r.y * rot.y, r.x * rot.y + r.y * rot.x);
}

// At most one star per grid cell; `threshold` sets how many cells are lit.
// Most pixels leave at one of the two early returns.
static inline float3 starLayer(float2 sp, float cells, float threshold,
                               float pxPerUnit, float pxPerPoint, float t64, float size) {
    float2 gp = sp * cells;
    float2 id = floor(gp);
    float3 h = hash32(id);
    if (h.z <= threshold) return float3(0.0);
    float mag = (h.z - threshold) / max(1.0 - threshold, 0.001);
    float2 d = (gp - id - (0.2 + 0.6 * h.xy)) * (pxPerUnit / cells);
    float b = mag * mag;
    float s = pxPerPoint * (0.62 + 0.80 * b) * size;
    float q = dot(d, d) / (s * s);
    if (q > 10.0) return float3(0.0);
    float k = 3.0 + floor(h.x * 13.0);
    float twinkle = 0.76 + 0.24 * sin(6.2831853 * (k * t64 / 64.0 + h.y));
    float3 tint = mix(float3(0.70, 0.81, 1.00), float3(1.00, 0.85, 0.68), h.x);
    return tint * ((0.05 + 0.95 * b) * exp(-q) * twinkle);
}

static inline float vignette(float2 w, float aspect) {
    float2 v = float2(w.x / aspect, w.y - 0.5);
    return 1.0 - 0.38 * dot(v, v);
}

// One LSB of interleaved-gradient-noise dither hides banding in dark gradients.
static inline float dither(float2 pixel) {
    return (fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715)))) - 0.5) / 255.0;
}

// MARK: Sky, soft parts (low resolution)

fragment float4 skyFragment(VOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            constant Pass &pass [[buffer(1)]],
                            texture2d<float> noise [[texture(0)]]) {
    float2 w = scenePoint(in, u.view.x, pass.r);
    float t = saturate((w.y - u.view.w) / (1.0 - u.view.w));

    float3 col = mix(u.horizon.rgb, u.zenith.rgb, (1.0 - exp(-3.2 * t)) * 1.0425);

    float2 ds = w - u.sun.xy;
    float r2 = dot(ds, ds);
    col += u.glow.rgb * (0.50 * exp(-r2 * 3.0) + 0.85 * exp(-r2 * 38.0)
                         + u.glow.a * exp(-t * 5.5) * exp(-ds.x * ds.x * 0.9));

    float2 dm = w - u.moon.xy;
    float m2 = dot(dm, dm);
    col += float3(0.50, 0.62, 0.90) * u.moonLight.w * (0.035 * exp(-m2 * 10.0) + 0.10 * exp(-m2 * 220.0));

    float density = 0.0;
    float sv = u.zenith.a;
    if (sv > 0.003) {
        float2 sp = starSpace(w, u.starRot);
        float c = length(sp - u.milky.xy) - u.milky.z;      // distance from the arch
        float band = exp(-c * c * 16.0);
        float2 n1 = noise.sample(tile, sp * 0.45 + float2(0.31, 0.17), level(0)).rg;
        float2 n2 = noise.sample(tile, sp * 1.10 + float2(0.73, 0.52), level(0)).rg;
        float body = saturate(n1.r * 1.6 - 0.25);
        float lane = 1.0 - 0.8 * smoothstep(0.46, 0.66, n2.g) * exp(-c * c * 70.0);
        density = band * body * lane * u.milky.w;
        float3 tint = mix(float3(0.50, 0.60, 1.00), float3(1.00, 0.82, 0.66),
                          saturate(n2.r * 1.5 - 0.35) * band);
        col += tint * (density * sv * 0.030);
    }

    if (u.aurora.x > 0.003) {
        // Three wavy curtains. Each has bright stretches and gaps along its
        // length, a crisp lower edge, and rays of uneven height.
        float3 acc = float3(0.0);
        for (int k = 0; k < 3; k++) {
            float fk = float(k);
            float a = w.x * 0.21 + fk * 0.37 + u.aurora.y;
            float2 n = noise.sample(tile, float2(a + u.clock.w * (1.0 + fk), 0.13 + fk * 0.21), level(0)).rg;
            float d = w.y - (0.46 + 0.07 * fk + 0.18 * (n.r - 0.5));
            if (d < -0.09 || d > 0.45) continue;       // this curtain doesn't reach here
            float ray = noise.sample(tile, float2(w.x * 2.2 + fk * 0.41 + n.r * 0.5,
                                                  0.61 + fk * 0.17 + u.clock.w * 2.0), level(0)).g;
            ray = smoothstep(0.24, 0.76, ray);
            float arc = smoothstep(0.38, 0.62, n.g);
            float profile = d > 0.0 ? exp(-d * mix(13.0, 7.0, ray)) * (1.0 - smoothstep(0.12, 0.45, d))
                                    : exp(d * 60.0);
            float3 c = mix(float3(0.10, 1.00, 0.45), float3(0.34, 0.14, 0.62), smoothstep(0.03, 0.26, d));
            acc += c * (profile * arc * (0.58 + 0.42 * ray) * (1.0 - 0.2 * fk));
        }
        col += acc * (u.aurora.x * 0.13);
    }

    float clear = 1.0;
    if (u.cloud.x > 0.01) {
        // a flat cloud deck seen in perspective: smaller and flatter toward the horizon
        float tt = t + 0.40;
        // The noise tile repeats, so a slow warp and a second octave at an
        // incommensurate scale keep the deck from repeating across a wide screen.
        // (The warp depends on x alone, so it slides clouds sideways without shearing them.)
        float warp = noise.sample(tile, float2(w.x * 0.045 + 0.2, 0.37), level(0)).g - 0.5;
        float2 P0 = float2(w.x / tt, 1.7 / tt + warp * 1.6) * 0.42;
        float2 P = P0 + float2(u.clock.y, 0.0);
        float na = noise.sample(tile, P, level(0)).r;
        float nb = noise.sample(tile, P0 * float2(2.37, 2.0) + float2(u.clock.z, 0.37), level(0)).g;
        float n = na * 0.62 + nb * 0.38;
        float th = mix(0.72, 0.42, u.cloud.x);
        float dens = smoothstep(th, th + 0.11, n) * smoothstep(0.0, 0.10, t);
        // bright rims, shaded hearts, and a little extra light on the side facing the sun
        float ns = noise.sample(tile, P + u.cloud.yz * 0.010, level(0)).r;
        float lit = saturate(1.0 - smoothstep(th + 0.06, th + 0.30, n) * 0.75 + (na - ns) * 2.5);
        float3 cc = mix(u.cloudShade.rgb, u.cloudLit.rgb, lit) + u.glow.rgb * (exp(-r2 * 6.0) * 0.6);
        col = mix(col, cc, dens * u.cloud.w);
        clear = 1.0 - dens;
    }

    // alpha tells the next pass how many stars to show here
    return float4(col, clear * (0.25 + 0.75 * saturate(density)));
}

// MARK: Nebula, soft parts (low resolution)

fragment float4 nebulaFragment(VOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               constant Pass &pass [[buffer(1)]],
                               texture2d<float> noise [[texture(0)]]) {
    float2 p = float2((in.uv.x - 0.5) * u.view.x, in.uv.y - 0.5) * 0.15;
    float3 ph = u.nebula.xyz;
    // domain warping: each lookup bends the coordinates of the next
    float2 q = noise.sample(tile, p + 0.05 * float2(cos(ph.x), sin(ph.x)), level(0)).rg - 0.5;
    float2 r = noise.sample(tile, p * 1.4 + q * 0.22 + 0.07 * float2(cos(ph.y), sin(ph.y)) + 0.31, level(0)).rg - 0.5;
    float2 fg = noise.sample(tile, p * 0.9 + r * 0.26 + 0.04 * float2(cos(ph.z), sin(ph.z)) + 0.67, level(0)).rg;
    float f = fg.r;

    float3 space  = float3(0.012, 0.016, 0.050);
    float3 indigo = float3(0.070, 0.090, 0.300);
    float3 teal   = float3(0.050, 0.420, 0.520);
    float3 violet = float3(0.520, 0.240, 0.720);
    float3 ember  = float3(1.000, 0.640, 0.460);

    // mostly dark space, with gas only where the warped field runs high
    float3 col = mix(space, indigo, smoothstep(0.22, 0.58, f));
    col = mix(col, teal, smoothstep(0.40, 0.76, f) * 0.80);
    col = mix(col, violet, smoothstep(-0.05, 0.20, r.y) * smoothstep(0.38, 0.72, f) * 0.75);
    col = mix(col, ember, smoothstep(0.60, 0.90, f) * smoothstep(0.40, 0.75, fg.g) * 0.85);
    return float4(col * col, 0.25 + 0.5 * f);
}

// MARK: Sky layer (one pixel per point)

fragment float4 starsFragment(VOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              constant Pass &pass [[buffer(1)]],
                              texture2d<float> sky [[texture(0)]],
                              texture2d<float> noise [[texture(1)]]) {
    float pxH = pass.r.z;
    float pt = pass.r.w;
    float2 w = scenePoint(in, u.view.x, pass.r);

    float4 s = sky.sample(edge, float2(in.uv.x, 1.0 - in.uv.y));
    float3 c = s.rgb;
    float hidden = 0.0;      // how much the sun or moon blocks the stars behind

    float2 dm = w - u.moon.xy;
    float md = length(dm);
    float mr = u.moon.z;
    if (md < mr + 2.0 / pxH && u.moon.w > 0.0) {
        float2 q = dm / mr;
        float z = sqrt(max(0.0, 1.0 - dot(q, q)));
        float lit = smoothstep(-0.04, 0.10, dot(float3(q, z), u.moonLight.xyz));
        float disc = saturate((mr - md) * pxH + 0.5);
        float maria = noise.sample(tile, q * 0.11 + 0.37, level(0)).r;
        float3 surface = float3(0.93, 0.92, 0.86) * ((0.66 + 0.5 * maria) * (0.55 + 0.45 * z));
        c += surface * surface * ((lit + 0.012) * disc * u.moon.w);
        hidden = disc;
    }

    // The sun adds light rather than painting a flat disc, so it is always
    // brighter than its own halo: white by day, molten at the horizon.
    float sd = length(w - u.sun.xy) / u.sun.z;
    float sunDisc = saturate((1.0 - sd) * u.sun.z * pxH * 0.5 + 0.5) * u.sun.w;
    c += u.sunColor.rgb * (sunDisc * (1.15 - 0.25 * sd * sd) + u.sun.w * 0.35 * exp(-sd * sd * 0.55));
    hidden = max(hidden, sunDisc);

    float sv = u.zenith.a * saturate(s.a * 4.0) * (1.0 - hidden);
    if (sv > 0.004) {
        float2 sp = starSpace(w, u.starRot);
        float dense = saturate((s.a - 0.25) * 1.3333);
        c += sv * (starLayer(sp, 34.0, 0.62, pxH, pt, u.clock.x, 1.0)
                   + starLayer(sp + 7.7, 95.0, 0.94 - 0.74 * dense, pxH, pt, u.clock.x, 0.75));
    }

    if (u.meteorB.x > 0.0) {
        float2 pa = w - u.meteorA.zw;
        float2 ba = u.meteorA.xy - u.meteorA.zw;
        float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
        float dl = length(pa - ba * h) * pxH / pt;
        float2 dh = (w - u.meteorA.xy) * pxH / pt;
        c += float3(0.85, 0.92, 1.00) * (u.meteorB.x * (0.9 * h * h * exp(-dl * dl / 1.2)
                                                       + 0.8 * exp(-dot(dh, dh) / 9.0)));
    }

    c = sqrt(max(c * vignette(w, u.view.x), 0.0)) + dither(in.pos.xy);
    return float4(c, 1.0);
}

fragment float4 plainFragment(VOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              constant Pass &pass [[buffer(1)]],
                              texture2d<float> sky [[texture(0)]]) {
    float2 w = scenePoint(in, u.view.x, pass.r);
    float4 s = sky.sample(edge, float2(in.uv.x, 1.0 - in.uv.y));
    float3 c = s.rgb + u.nebula.w * (starLayer(w, 34.0, 0.70, pass.r.z, pass.r.w, u.clock.x, 1.0)
                                     + starLayer(w + 7.7, 95.0, 0.99 - 0.5 * s.a, pass.r.z, pass.r.w, u.clock.x, 0.75));
    c = sqrt(max(c * vignette(w, u.view.x), 0.0)) + dither(in.pos.xy);
    return float4(c, 1.0);
}

// MARK: Ridge layer (full resolution, drawn rarely, premultiplied alpha)

fragment float4 ridgeFragment(VOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              constant Pass &pass [[buffer(1)]],
                              texture2d<float> ridges [[texture(0)]],
                              texture2d<float> noise [[texture(1)]]) {
    float pxH = pass.r.z;
    float2 w = scenePoint(in, u.view.x, pass.r);

    float3 acc = float3(0.0);
    float trans = 1.0;

    // Nearest ridge first, stopping as soon as the pixel is covered.
    for (int i = 0; i < LAYERS; i++) {
        Layer L = u.layers[i];
        if (w.y > L.geo.z) continue;
        float2 hs = ridges.sample(ridgeSampler,
                                  float2(w.x * L.geo.x + L.geo.y, (float(i) + 0.5) / float(LAYERS)),
                                  level(0)).rg;
        float d = hs.r - w.y;
        float slope = hs.g * L.geo.x;
        float cov = saturate(0.5 + d * pxH * rsqrt(1.0 + slope * slope));
        if (cov <= 0.0) continue;

        float m = noise.sample(tile, float2(w.x * 0.5 + L.geo.w, w.y * 2.0 + float(i) * 0.19), level(0)).g;
        float fog = saturate(d * 5.5) * saturate(0.45 + (m - 0.5) * 2.2) * L.base.a;
        float3 c = mix(L.crest.rgb, L.base.rgb, fog);
        float sx = w.x - u.sun.x;
        c += u.glow.rgb * (L.crest.a * L.crest.a * 0.35 * exp(-sx * sx * 1.4) * exp(-d * 9.0));

        acc += c * (trans * cov);
        trans *= 1.0 - cov;
        if (trans < 0.004) break;
    }

    // acc is colour × coverage, so sqrt(acc × alpha) is the encoded colour × alpha
    float alpha = 1.0 - trans;
    float3 c = sqrt(max(acc * vignette(w, u.view.x) * alpha, 0.0)) + dither(in.pos.xy) * alpha;

    // a lit window on one of the hills, after dark
    float2 dc = (w - u.cabin.xy) * pxH / pass.r.w;
    float c2 = dot(dc, dc);
    c += float3(1.00, 0.72, 0.38) * (u.cabin.z * (0.95 * exp(-c2 / 3.0) + 0.16 * exp(-c2 / 160.0)));

    return float4(c, alpha);
}
