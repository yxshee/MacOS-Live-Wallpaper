// Hyperspace by Mårten Rånge (mrange)
// https://github.com/mrange/synesthesia-public/tree/main/hyperspace.synScene
// The original main.glsl has no header comment of its own. It is covered by the
// repository's LICENSE, CC0 1.0 Universal (public domain dedication).
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the
// original:
//  - The Synesthesia wrapper is removed (fpass0/fpass1/renderMain, _uvc and the
//    control uniforms). The controls are fixed at their defaults: trail 0.3,
//    rotation 0.4 and speed 2 (both are "speed" controls, accumulated over
//    time), color_base (2,1).
//  - The audio input syn_BassHits is replaced by 0, so its term drops out.
//  - The media layer (pass 1 mixing in a video) is dropped. Its final sqrt stays.
//  - The trail feedback (pass 0 reading its own previous frame) is folded into
//    one pass: the last TRAIL_STEPS frames of the original's 60 fps sequence are
//    re-evaluated for the same pixel and blended with the original's recurrence.
//    The oldest frame of that chain is the smooth background glow alone, so the
//    far end of a trail is up to about 12% fainter than the original's.
//  - The whole animation runs at TIMESCALE (a quarter) of the original's speed,
//    which at 15 fps advances one original frame per drawn frame. The original
//    flies at 2 cells a second, which is too restless for a desktop. The clock
//    wraps after 20000 original seconds (22 hours of running) to keep the float
//    maths exact; that is one jump in the scene, once a day.
//  - GLSL to Metal syntax. The tanh input is clamped to 10 (no visible change),
//    and sin(a+2), sin(a+1), sin(a) come from one sin and one cos of a (same
//    values).

#define TIMESCALE   0.25
#define TIMEWRAP    20000.0
#define TRAIL       0.3
#define TRAIL_DT    (1.0/60.0)
#define TRAIL_STEPS 6

// One frame of pass 0 without the feedback blend. tau is the original's time in
// seconds. With stars false only the smooth background glow is returned.
vec3 hyperspaceFrame(vec2 uvc, float tau, bool stars)
{
  float speed    = 2.0*tau;
  float rotation = 0.4*tau;
  float z        = speed;

  vec2 P = vec2(1.0, 0.707)/9.0;
  vec2 C = vec2(0.0);

  vec3 D = vec3(0.0);
  vec3 Z = normalize(vec3(2.0*P*cos(P*z), 1.0));
  vec3 X = vec3(-Z.z, 0.0, Z.x);
  vec3 O = vec3(2.0*sin(P*z), z);
  vec3 I = normalize(uvc.y*cross(X,Z) - uvc.x*X + 0.5*Z);
  vec3 p = vec3(0.0);
  vec3 o = 1.0/(1.03-I.z-I.y*I.y/3.0)*vec3(4.0,12.0,36.0);

  if (stars) {
    z = fract(-z)/I.z;
    I.xy = I.xy*mat2(cos(rotation), cos(rotation+11.0), cos(rotation+33.0), cos(rotation));

    mat3 H = mat3(13.0,78.0,38.0, 39.0,68.0,23.0, 48.0,82.0,16.0);

    for (int i=0; i<16; ++i) {
      p = z*I+O;
      D = round(p);
      p -= D;
      D = fract(sin(D*H)*9e3)-0.5;
      C = (p-0.8*D).xy;
      float s = sin(9.0*D.z);
      float c = cos(9.0*D.z);
      // sin(a+2), sin(a+1), sin(a) with a = 9*D.z
      vec3 col = vec3(s*-0.41614684+c*0.9092974, s*0.5403023+c*0.84147098, s);
      o += exp(-z*z/67.0)
         / max(dot(C,C),1e-4)
         * (1.1+col);
      z += 1.0/I.z;
    }
  }

  o = o/3e3-vec3(3.0,9.0,1.0)/1e2;
  o = max(o,0.0);
  o = tanh(min(o,10.0));
  return o;
}

void mainImage(thread vec4& fragColor, vec2 fragCoord)
{
  vec2 uvc = (fragCoord/iResolution.xy-0.5)*vec2(iResolution.x/iResolution.y, 1.0);
  float tau = mod(iTime*TIMESCALE, TIMEWRAP);
  vec3 lum = vec3(0.2126, 0.7152, 0.0722);

  // The feedback buffer, unrolled: out = mix(previous, now, mix(trail, 1, luma(now))).
  vec3 acc = hyperspaceFrame(uvc, tau-float(TRAIL_STEPS)*TRAIL_DT, false);
  for (int k=TRAIL_STEPS-1; k>=0; --k) {
    vec3 o = hyperspaceFrame(uvc, tau-float(k)*TRAIL_DT, true);
    acc = mix(acc, o, mix(TRAIL, 1.0, dot(lum, o)));
  }

  fragColor = vec4(sqrt(acc), 1.0);
}
