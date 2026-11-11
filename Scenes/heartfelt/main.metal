// Heartfelt - by Martijn Steinrucken aka BigWings - 2017
// Email:countfrolic@gmail.com Twitter:@The_ArtOfCode
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.

// I revisited the rain effect I did for another shader. This one is better in multiple ways:
// 1. The glass gets foggy.
// 2. Drops cut trails in the fog on the glass.
// 3. The amount of rain is adjustable (with Mouse.y)

// To have full control over the rain, uncomment the HAS_HEART define

// A video of the effect can be found here:
// https://www.youtube.com/watch?v=uiF5Tlw22PI&feature=youtu.be

// Music - Alone In The Dark - Vadim Kiselev
// https://soundcloud.com/ahmed-gado-1/sad-piano-alone-in-the-dark
// Rain sounds:
// https://soundcloud.com/elirtmusic/sleeping-sound-rain-and-thunder-1-hours

// ---------------------------------------------------------------------------
// Ported to Metal Shading Language for MacOS Live Wallpaper.
// Source of the port: Heartfelt.frag from the KDE Shader Wallpaper project,
// https://github.com/y4my4my4m/kde-shader-wallpaper (a copy of the Shadertoy
// shader with the author's header intact).
//
// Changes from the original:
//  - mainImage's output parameter is written the Metal way (thread vec4&).
//  - The image the original refracts (a photo supplied by the host) cannot be
//    shipped. It is replaced by LwNight() below, a soft procedural picture of
//    blurred night-city lights that the port ADDS. It is not part of the
//    original and is not the author's work. It is asked for the same mip level
//    ("focus") the original gave textureLod, so the glass blurs it the same way.
//  - Mouse input is gone (a wallpaper has none): the mouse branches take their
//    no-mouse values, so rain amount and time run as the author's defaults.
//  - Time runs at LW_RATE (60%) of real time, so the story and the drops move
//    more slowly, which suits a desktop and keeps the quick static droplets from
//    flickering at a low frame rate. The story clock also starts LW_START (10 s) in.
//  - The author faded the picture to black at each end of the 102-second story,
//    which on a desktop would black out the wallpaper every three minutes. The
//    picture is no longer faded. Instead, for the first LW_BLEND seconds of each
//    story the end of the one before (carried on past 102 s) dissolves into it.
//    The author's fade still shapes the lightning glow, as it did before.
//  - The lightning flash had a fast flicker term that strobes at wallpaper frame
//    rates. It is replaced by a gentle, much weaker glow on the same schedule.
//  - S() is written out as the clamp-and-Hermite formula, because many calls
//    pass the edges in reverse order, which Metal's smoothstep leaves undefined.
//  - "col *= 1.-dot(UV-=.5, UV)" is split in two statements: it used UV on both
//    sides of a modification in one call, whose order is not fixed in Metal.
//  - The two "@texture0 / @channels" lines of the host project's header are
//    dropped; they were instructions to that host, not the author's text.
//  - HAS_HEART stays defined, as in the host project's copy, so the 102-second
//    heart story plays. The mouse-driven rain amount and the #else branch are
//    left in place but unused.
//
// Third-party note: N13() below is the author's hash. He credits it in his own
// comment to Dave Hoskins ("Hash without Sine"). It is kept exactly as he wrote
// it. See LICENSE for what is known about that credit.
// ---------------------------------------------------------------------------

#define LW_RATE .6
#define LW_START 10.
#define LW_BLEND 6.

// Smoothstep with an explicit formula (edges may be given in reverse order).
float S(float a, float b, float t) {
    float d = b - a;
    d = abs(d) < 1e-6 ? 1e-6 : d;
    float x = clamp((t - a) / d, 0., 1.);
    return x * x * (3. - 2. * x);
}
//#define CHEAP_NORMALS
#define HAS_HEART
#define USE_POST_PROCESSING

vec3 N13(float p) {
    //  from DAVE HOSKINS
   vec3 p3 = fract(vec3(p) * vec3(.1031,.11369,.13787));
   p3 += dot(p3, p3.yzx + 19.19);
   return fract(vec3((p3.x + p3.y)*p3.z, (p3.x+p3.z)*p3.y, (p3.y+p3.z)*p3.x));
}

vec4 N14(float t) {
    return fract(sin(t*vec4(123., 1024., 1456., 264.))*vec4(6547., 345., 8799., 1564.));
}
float N(float t) {
    return fract(sin(t*12345.564)*7658.76);
}

float Saw(float b, float t) {
    return S(0., b, t)*S(1., b, t);
}


vec2 DropLayer2(vec2 uv, float t) {
    vec2 UV = uv;

    uv.y += t*0.75;
    vec2 a = vec2(6., 1.);
    vec2 grid = a*2.;
    vec2 id = floor(uv*grid);

    float colShift = N(id.x);
    uv.y += colShift;

    id = floor(uv*grid);
    vec3 n = N13(id.x*35.2+id.y*2376.1);
    vec2 st = fract(uv*grid)-vec2(.5, 0);

    float x = n.x-.5;

    float y = UV.y*20.;
    float wiggle = sin(y+sin(y));
    x += wiggle*(.5-abs(x))*(n.z-.5);
    x *= .7;
    float ti = fract(t+n.z);
    y = (Saw(.85, ti)-.5)*.9+.5;
    vec2 p = vec2(x, y);

    float d = length((st-p)*a.yx);

    float mainDrop = S(.4, .0, d);

    float r = sqrt(S(1., y, st.y));
    float cd = abs(st.x-x);
    float trail = S(.23*r, .15*r*r, cd);
    float trailFront = S(-.02, .02, st.y-y);
    trail *= trailFront*r*r;

    y = UV.y;
    float trail2 = S(.2*r, .0, cd);
    float droplets = max(0., (sin(y*(1.-y)*120.)-st.y))*trail2*trailFront*n.z;
    y = fract(y*10.)+(st.y-.5);
    float dd = length(st-vec2(x, y));
    droplets = S(.3, 0., dd);
    float m = mainDrop+droplets*r*trailFront;

    //m += st.x>a.y*.45 || st.y>a.x*.165 ? 1.2 : 0.;
    return vec2(m, trail);
}

float StaticDrops(vec2 uv, float t) {
    uv *= 40.;

    vec2 id = floor(uv);
    uv = fract(uv)-.5;
    vec3 n = N13(id.x*107.45+id.y*3543.654);
    vec2 p = (n.xy-.5)*.7;
    float d = length(uv-p);

    float fade = Saw(.025, fract(t+n.z));
    float c = S(.3, 0., d)*fract(n.z*10.)*fade;
    return c;
}

vec2 Drops(vec2 uv, float t, float l0, float l1, float l2) {
    float s = StaticDrops(uv, t)*l0;
    vec2 m1 = DropLayer2(uv, t)*l1;
    vec2 m2 = DropLayer2(uv*1.85, t)*l2;

    float c = s+m1.x+m2.x;
    c = S(.3, 1., c);

    return vec2(c, max(m1.y*l0, m2.y*l1));
}

// ---------------------------------------------------------------------------
// ADDED BY THE PORT, not part of the original: soft night-city bokeh.
// uv is 0..1 with the origin at the bottom left; lod plays the part of the mip
// level the original asked of its photo (bigger = blurrier).
// ---------------------------------------------------------------------------
vec3 LwLight(float k) {
    // a palette of street-light, window and neon colours, picked by k in 0..1
    vec3 c = vec3(1.00, .60, .26);                         // sodium amber
    c = k > .34 ? vec3(1.00, .84, .60) : c;                // warm white
    c = k > .58 ? vec3(.62, .80, 1.00) : c;                // cool white
    c = k > .72 ? vec3(1.00, .22, .20) : c;                // red
    c = k > .82 ? vec3(.95, .28, .68) : c;                 // magenta neon
    c = k > .90 ? vec3(.20, .85, .90) : c;                 // teal neon
    c = k > .96 ? vec3(.40, 1.00, .50) : c;                // green
    return c;
}

// One layer of lights on a jittered grid. size: cell size, r0: light radius,
// bright: brightness, top: the lights stay below this height, layer: seed.
vec3 LwLayer(vec2 p, float w, float size, float r0, float bright, float top, float layer) {
    vec2 g = p / size;
    vec2 id = floor(g);
    vec3 col = vec3(0.);
    float wl = min(w, .9 * size);                          // keep the blur inside the 3x3 cells
    float R = sqrt(r0 * r0 + .25 * wl * wl);               // blurred radius
    float e = .3 * R + .25 * wl;                           // soft edge
    float energy = pow(r0 / R, 1.4);                       // a bigger blur is dimmer
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 q = id + vec2(float(i), float(j));
            float s = layer * 7.31 + q.x * .731 + q.y * 1.913;
            vec2 c = (q + .15 + .7 * vec2(N(s), N(s + 1.7))) * size;
            // the skyline: building tops step up and down along x, and the
            // lights thin out towards the top of each building
            float sky = top * (.5 + .5 * N(floor(c.x / .17) * .93 + layer));
            float dens = .8 * (1. - .85 * c.y / sky);
            float on = step(N(s + 3.9), dens) * step(c.y, sky);
            float d = length(p - c);
            float v = S(R + e, R - e, d);
            col += LwLight(N(s + 5.3)) * v * on * (.5 + .5 * N(s + 8.1)) * bright * energy;
        }
    }
    return col;
}

vec3 LwNight(vec2 uv, float lod) {
    float asp = iResolution.x / iResolution.y;
    vec2 p = vec2(uv.x * asp, uv.y);
    float w = exp2(lod) * (.8 / 1024.);                    // blur width, in screen heights

    // night sky, a little lighter and warmer towards the horizon
    vec3 col = mix(vec3(.020, .026, .075), vec3(.085, .060, .150), S(.95, .15, uv.y));

    // the city's glow on the haze: broad patches of warm and cool light that
    // stay visible however much the glass blurs them
    float hx = uv.x * asp;
    float warm = .5 + .5 * sin(hx * 2.3 + 1.0 + .8 * sin(hx * .9));
    vec3 haze = mix(vec3(.55, .22, .10), vec3(.18, .20, .55), warm);
    haze = mix(haze, vec3(.50, .12, .35), S(.55, .95, .5 + .5 * sin(hx * 1.7 + 4.0)) * .6);
    col += haze * S(.78, .0, uv.y) * (.22 + .12 * sin(hx * 5.1 + 2.0));

    col += LwLayer(p, w, .060, .012, 1.10, .80, 1.);       // windows and lamps, far
    col += LwLayer(p, w, .115, .026, 1.15, .62, 2.);       // signs and lights, mid
    col += LwLayer(p, w, .230, .050, 1.20, .42, 3.);       // big near lights
    return col;
}

// The author's mainImage, for a given moment T of the story.
vec3 LwStory( vec2 fragCoord, float T )
{
    vec2 uv = (fragCoord.xy-.5*iResolution.xy) / iResolution.y;
    vec2 UV = fragCoord.xy/iResolution.xy;


    float t = T*.2;

    float rainAmount = sin(T*.05)*.3+.7;

    float maxBlur = mix(3., 6., rainAmount);
    float minBlur = 2.;

    float story = 0.;
    float heart = 0.;

    #ifdef HAS_HEART
    story = S(0., 70., T);

    t = min(1., T/70.);                     // remap drop time so it goes slower when it freezes
    t = 1.-t;
    t = (1.-t*t)*70.;

    float zoom= mix(.3, 1.2, story);        // slowly zoom out
    uv *=zoom;
    minBlur = 4.+S(.5, 1., story)*3.;       // more opaque glass towards the end
    maxBlur = 6.+S(.5, 1., story)*1.5;

    vec2 hv = uv-vec2(.0, -.1);             // build heart
    hv.x *= .5;
    float s = S(110., 70., T);              // heart gets smaller and fades towards the end
    hv.y-=sqrt(abs(hv.x))*.5*s;
    heart = length(hv);
    heart = S(.4*s, .2*s, heart)*s;
    rainAmount = heart;                     // the rain is where the heart is

    maxBlur-=heart;                         // inside the heart slighly less foggy
    uv *= 1.5;                              // zoom out a bit more
    t *= .25;
    #else
    float zoom = -cos(T*.2);
    uv *= .7+zoom*.3;
    #endif
    UV = (UV-.5)*(.9+zoom*.1)+.5;

    float staticDrops = S(-.5, 1., rainAmount)*2.;
    float layer1 = S(.25, .75, rainAmount);
    float layer2 = S(.0, .5, rainAmount);


    vec2 c = Drops(uv, t, staticDrops, layer1, layer2);
   #ifdef CHEAP_NORMALS
        vec2 n = vec2(dFdx(c.x), dFdy(c.x));// cheap normals (3x cheaper, but 2 times shittier ;))
    #else
        vec2 e = vec2(.001, 0.);
        float cx = Drops(uv+e, t, staticDrops, layer1, layer2).x;
        float cy = Drops(uv+e.yx, t, staticDrops, layer1, layer2).x;
        vec2 n = vec2(cx-c.x, cy-c.x);      // expensive normals
    #endif


    #ifdef HAS_HEART
    n *= 1.-S(60., 85., T);
    c.y *= 1.-S(80., 100., T)*.8;
    #endif

    float focus = mix(maxBlur-c.y, minBlur, S(.1, .2, c.x));
    // the original: vec3 col = textureLod(iChannel0, UV+n, focus).rgb;
    vec3 col = LwNight(UV+n, focus);


    #ifdef USE_POST_PROCESSING
    t = (T+3.)*.5;                                      // make time sync with first lightnoing
    float colFade = sin(t*.2)*.5+.5+story;
    col *= mix(vec3(1.), vec3(.8, .9, 1.3), colFade);   // subtle color shift
    float fade = S(0., 10., T);                         // fade in at the start
    float lightning = pow(max(0., sin(t+sin(t))), 10.) * .2;   // gentle lightning glow (the original also flickered, see above)
    col *= 1.+lightning*fade*mix(1., .1, story*story);  // composite lightning
    UV -= .5;
    col *= 1.-dot(UV, UV);                              // vignette

    #ifdef HAS_HEART
        col = mix(pow(col, vec3(1.2)), col, heart);
        fade *= S(102., 97., T);
    #endif

    // the original: col *= fade;  (start and end fade to black; see the note at the top)
    #endif

    //col = vec3(heart);
    return col;
}

void mainImage( thread vec4& fragColor, in vec2 fragCoord )
{
    float T = mod(iTime * LW_RATE + LW_START, 102.);
    // One call site in a loop, so the compiler builds the big function once.
    int passes = T < LW_BLEND ? 2 : 1;
    vec3 col = vec3(0.);
    for (int i = 0; i < passes; i++) {
        vec3 c = LwStory(fragCoord, i == 0 ? T : T + 102.);
        if (i == 0) col = c; else col = mix(c, col, S(0., LW_BLEND, T));
    }
    fragColor = vec4(col, 1.);
}
