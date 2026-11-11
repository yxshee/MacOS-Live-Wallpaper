// License CC0: Sea and moon
//  Tinkering with the colors of an old shaders to make it a better fit for windows terminal
//
// Sea and Moon by Mårten Rånge (mrange)
// https://www.shadertoy.com/view/csfXzN
// Ported from the author's own HLSL version in
// https://github.com/mrange/windows-terminal-shader-gallery (gallery/sea-and-moon),
// whose metadata.json lists the licence as CC0-1.0.
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the
// original:
//  - The Windows Terminal wrapper is gone: the PixelShaderSettings buffer, the
//    shaderTexture / samplerState pair and the blending of the terminal's text
//    (fg / sh) over the picture. The shader draws the picture only.
//  - Time and resolution come from iTime and iResolution. Fragment coordinates
//    already have a bottom-left origin, so the terminal's "p.y = -p.y" flip is
//    not needed.
//  - HLSL names became GLSL / Metal names (lerp -> mix, frac -> fract, static
//    const -> const, inout -> thread&). The mod() adapter is dropped (the
//    prelude has one) and the unit2/unit3/unit4 constants, which were only
//    used to write zero vectors, became plain vec3(0.0). dot(dsea, dsea) on a
//    scalar is written dsea*dsea.
//  - tanh_approx() is replaced by the built-in tanh(). (The original marks that
//    helper "License: Unknown, author: Unknown" and comments it as an
//    approximation of tanh.) The argument is capped at 15, because Metal's tanh
//    overflows to NaN for large inputs and k*h reaches 157 here. Every call has
//    k*h >= 25, where tanh_approx clamps to exactly 1.0 and tanh(15) is also
//    1.0 in float, so the picture is unchanged (checked pixel for pixel at
//    three times).
//  - The wave motion and timing are unchanged from the original. The unused
//    local d2 in sea() and the unused TAU constant are left out.

#define PI 3.141592654

const float gravity = 1.0;
const float waterTension = 0.01;

const vec3 skyCol1 = vec3(0.6, 0.35, 0.3).zyx*0.5;
const vec3 skyCol2 = vec3(1.0, 0.3, 0.3).zyx*0.5;
const vec3 sunCol1 = vec3(1.0, 0.5, 0.4).zyx;
const vec3 sunCol2 = vec3(1.0, 0.8, 0.8).zyx;
const vec3 seaCol1 = vec3(0.1, 0.2, 0.2)*0.2;
const vec3 seaCol2 = vec3(0.2, 0.9, 0.6)*0.5;

vec2 wave(float t, float a, float w, float p) {
  float x = t;
  float y = a*sin(t*w + p);
  return vec2(x, y);
}

vec2 dwave(float t, float a, float w, float p) {
  float dx = 1.0;
  float dy = a*w*cos(t*w + p);
  return vec2(dx, dy);
}

vec2 gravityWave(float t, float a, float k, float h) {
  float w = sqrt(gravity*k*tanh(min(k*h, 15.0)));
  return wave(t, a, k, w*iTime);
}

vec2 capillaryWave(float t, float a, float k, float h) {
  float w = sqrt((gravity*k + waterTension*k*k*k)*tanh(min(k*h, 15.0)));
  return wave(t, a, k, w*iTime);
}

vec2 gravityWaveD(float t, float a, float k, float h) {
  float w = sqrt(gravity*k*tanh(min(k*h, 15.0)));
  return dwave(t, a, k, w*iTime);
}

vec2 capillaryWaveD(float t, float a, float k, float h) {
  float w = sqrt((gravity*k + waterTension*k*k*k)*tanh(min(k*h, 15.0)));
  return dwave(t, a, k, w*iTime);
}

void mrot(thread vec2& p, float a) {
  float c = cos(a);
  float s = sin(a);
  p = vec2(c*p.x + s*p.y, -s*p.x + c*p.y);
}

vec4 sea(vec2 p, float ia) {
  float y = 0.0;
  vec3 d = vec3(0.0);

  const int maxIter = 8;
  const int midIter = 4;

  float kk = 1.0/1.3;
  float aa = 1.0/(kk*kk);
  float k = 1.0*pow(kk, -float(maxIter) + 1.0);
  float a = ia*0.25*pow(aa, -float(maxIter) + 1.0);

  float h = 25.0;
  p *= 0.5;

  vec2 waveDir = vec2(0.0, 1.0);
{
  for (int i = midIter; i < maxIter; ++i) {
    float t = dot(-waveDir, p) + float(i);
    y += capillaryWave(t, a, k, h).y;
    vec2 dw = capillaryWaveD(-t, a, k, h);

    d += vec3(waveDir.x, dw.y, waveDir.y);

    mrot(waveDir, PI/3.0);

    k *= kk;
    a *= aa;
  }
}
  waveDir = vec2(0.0, 1.0);
{
  for (int i = 0; i < midIter; ++i) {
    float t = dot(waveDir, p) + float(i);
    y += gravityWave(t, a, k, h).y;
    vec2 dw = gravityWaveD(t, a, k, h);

    d += vec3(waveDir.x, dw.y, waveDir.y);

    mrot(waveDir, -step(2.0, float(i)));

    k *= kk;
    a *= aa;
  }
}
  vec3 t = normalize(d);
  vec3 nxz = normalize(vec3(t.z, 0.0, -t.x));
  vec3 nor = cross(t, nxz);

  return vec4(y, nor);
}

vec3 sunDirection() {
  vec3 dir = normalize(vec3(0.0, 0.06, 1.0));
  return dir;
}

vec3 skyColor(vec3 rd) {
  vec3 sunDir = sunDirection();
  float sunDot = max(dot(rd, sunDir), 0.0);
  vec3 final = vec3(0.0);
  final += mix(skyCol1, skyCol2, rd.y);
  final += 0.5*sunCol1*pow(sunDot, 90.0);
  final += 4.0*sunCol2*pow(sunDot, 900.0);
  return final;
}

vec3 render(vec3 ro, vec3 rd) {
  vec3 col = vec3(0.0);

  float dsea = (0.0 - ro.y)/rd.y;

  vec3 sunDir = sunDirection();

  vec3 sky = skyColor(rd);

  if (dsea > 0.0) {
    vec3 p = ro + dsea*rd;
    vec4 s = sea(p.xz, 1.0);
    float h = s.x;
    vec3 nor = s.yzw;
    nor = mix(nor, vec3(0.0, 1.0, 0.0), smoothstep(0.0, 200.0, dsea));

    float fre = clamp(1.0 - dot(-nor, rd), 0.0, 1.0);
    fre = fre*fre*fre;
    float dif = mix(0.25, 1.0, max(dot(nor, sunDir), 0.0));

    vec3 refl = skyColor(reflect(rd, nor));
    vec3 refr = seaCol1 + dif*sunCol1*seaCol2*0.1;

    col = mix(refr, 0.9*refl, fre);

    float atten = max(1.0 - dsea*dsea * 0.001, 0.0);
    col += seaCol2*(p.y - h) * 2.0 * atten;

    col = mix(col, sky, 1.0 - exp(-0.01*dsea));

  } else {
    col = sky;
  }

  return col;
}

vec3 effect(vec2 p) {
  vec3 ro = vec3(0.0, 10.0, 0.0);
  vec3 ww = normalize(vec3(0.0, -0.1, 1.0));
  vec3 uu = normalize(cross(vec3(0.0, 1.0, 0.0), ww));
  vec3 vv = normalize(cross(ww, uu));
  vec3 rd = normalize(p.x*uu + p.y*vv + 2.5*ww);

  vec3 col = render(ro, rd);

  return col;
}

void mainImage(thread vec4& fragColor, vec2 fragCoord) {
  vec2 q = fragCoord/iResolution.xy;
  vec2 p = -1.0 + 2.0*q;
  p.x *= iResolution.x/iResolution.y;

  vec3 col = effect(p);

  fragColor = vec4(col, 1.0);
}
