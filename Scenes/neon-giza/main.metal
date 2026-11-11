// This file is released under CC0 1.0 Universal (Public Domain Dedication).
// To the extent possible under law, Mårten Rånge has waived all copyright
// and related or neighboring rights to this work.
// See <https://creativecommons.org/publicdomain/zero/1.0/> for details.
//
// Neon Giza by Mårten Rånge (mrange), a Synesthesia scene.
// https://github.com/mrange/synesthesia-public/tree/main/neon_giza.synScene
//
// Ported to Metal Shading Language for MacOS Live Wallpaper.
// Changes from the original:
//  - The Synesthesia wrapper is gone. Its two passes are folded into
//    mainImage(): pass 0 (the ray marcher) and the tone-mapping of pass 1
//    (clamp, tanh_approx, sqrt) now run in one go. Synesthesia's _uv, _uvc,
//    _xy and RENDERSIZE are rebuilt from fragCoord and iResolution.
//  - Audio is replaced by slow sines: beat(), freq() and wave() no longer read
//    the bass and spectrum inputs, and syn_BassTime is gone from the travel
//    time. The sliders are constants at their scene.json defaults
//    (motion_blur 0.3 is the exception, see below).
//  - The hue_offset slider is fixed at its default, 0.725, and the colours
//    that script.js computed each frame are the author's own HSV2RGB macro
//    with that offset. The KODELIFE-only code and the unused toScreenSpace()
//    were dropped.
//  - The scene runs at 0.3 of its original speed (TIME below), which keeps
//    camera travel, arc spin and the sines in step with each other.
//  - Pass 1 also blended in the previous frame (motion_blur) and a user media
//    layer. Neither exists here, so both are gone and the picture is a touch
//    crisper.
//  - Pass 1's noise filter (reduceNoise) read four neighbouring pixels of
//    pass 0, which a single pass cannot do. It is left out; at this scene's
//    resolution the unfiltered picture is the cleaner one.
//  - Two helpers that the original marks "License: Unknown" are not carried
//    over. tanh_approx() (a rational approximation of tanh) is replaced by the
//    built-in tanh(), with its argument capped because Metal's tanh overflows
//    for large inputs; the tone curve differs from the approximation by under
//    2 per cent. hash() is replaced by an integer hash written for this port,
//    so the arcs' random tilts are different numbers of the same kind.
//  - Metal syntax: out/inout parameters became thread references (a swizzle
//    cannot be passed that way, so the two rot(p.xy, ...) calls go through a
//    temporary), `rd *= m` became `rd = rd * m`, any() around a vector !=,
//    `bn` and `iter` are initialised, PI and radians() are defined, and the
//    four smoothstep calls with reversed edges use a small helper with the
//    same formula.

#define PI 3.141592653589793
#define radians(a) ((a)*(PI/180.0))
#define TIME (iTime*0.3)

// License: WTFPL, author: sam hocevar, found: https://stackoverflow.com/a/17897228/418488
const vec4 hsv2rgb_K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
vec3 hsv2rgb(vec3 c) {
  vec3 p = abs(fract(c.xxx + hsv2rgb_K.xyz) * 6.0 - hsv2rgb_K.www);
  return c.z * mix(hsv2rgb_K.xxx, clamp(p - hsv2rgb_K.xxx, 0.0, 1.0), c.y);
}
// License: WTFPL, author: sam hocevar, found: https://stackoverflow.com/a/17897228/418488
//  Macro version of above to enable compile-time constants
#define HSV2RGB(c)  (c.z * mix(hsv2rgb_K.xxx, clamp(abs(fract(c.xxx + hsv2rgb_K.xyz) * 6.0 - hsv2rgb_K.www) - hsv2rgb_K.xxx, 0.0, 1.0), c.y))

// Slider defaults from scene.json (hue_offset, bar_height, bar_visibility,
// travel_speed.x). Every other slider is described in the header above.
const float
  bar_height    =.125
, bar_visibility=1.0
, hoff          = 0.725
;

const vec2
  travel_speed=vec2(5,0)
;

// The colours script.js sets with setHSVColor() from hue_offset.
const vec3
  sunColor   = HSV2RGB(vec3(hoff+0.0, 0.9, .0005))
, topColor   = HSV2RGB(vec3(hoff+0.0, 0.9, .0001))
, glowColor0 = HSV2RGB(vec3(hoff+0.0, 0.9, .0001))
, glowColor2 = HSV2RGB(vec3(hoff+0.3, .95, .001))
, diffColor  = HSV2RGB(vec3(hoff+0.0, 0.5, .25))
, glowCol1   = HSV2RGB(vec3(hoff+0.2, .85, .0125))
, barCol     = HSV2RGB(vec3(hoff+0.15,.90, 1.))
;

const float
  TAU                 = 2.*PI
, MAX_RAY_LENGTH_HI   = 60.0
, TOLERANCE_HI        = 1e-4
, MAX_RAY_MARCHES_HI  = 70.
, NORM_OFF            = 5e-3
;

#define ROT(a)              mat2(cos(a), sin(a), -sin(a), cos(a))
#define SCA(a)              vec2(sin(a), cos(a))

#define ROTY(a)               \
  mat3(                       \
    +cos(a) , 0.0 , +sin(a)   \
  , 0.0     , 1.0 , 0.0       \
  , -sin(a) , 0.0 , +cos(a)   \
  )

#define ROTZ(a)               \
  mat3(                       \
    +cos(a) , +sin(a) , 0.0   \
  , -sin(a) , +cos(a) , 0.0   \
  , 0.0     , 0.0     , 1.0   \
  )

#define ROTX(a)               \
  mat3(                       \
    1.0 , 0.0     , 0.0       \
  , 0.0 , +cos(a) , +sin(a)   \
  , 0.0 , -sin(a) , +cos(a)   \
  )


const float
  PERIOD=300.
;

const vec2
  PATHA = (TAU/PERIOD*vec2(3,2))
, PATHB = (vec2(2, 3))
;

const mat2
  R45 = ROT(-PI/4.)
;

const mat3
  rotx = ROTX(radians(-51.8))
, rr0  = rotx
, rr1  = rr0*ROTY(PI/2.0)
;

const vec3
  n0   = normalize(vec3(.0, 0.0, 1.0))*rr0
, c0   = vec3(0.0)
, n1   = normalize(vec3(.0, 0.0, 1.0))*rr1
, c1   = vec3(0.0)
;

const vec4
  dim0 = vec4(n0, -dot(c0, n0))
, dim1 = vec4(n1, -dot(c1, n1))
;

vec3 path(float z) {
  return vec3(sin(z*PATHA)*PATHB, z);
}

vec3 dpath(float z) {
  return vec3(PATHA*PATHB*cos(PATHA*z), 1);
}

vec3 ddpath(float z) {
  return vec3(-PATHA*PATHA*PATHB*sin(PATHA*z), 0);
}

// Written for this port (see the note at the top): the built-in tanh, with
// the argument kept where Metal's tanh cannot overflow.
float tanh_approx(float x) {
  return tanh(clamp(x, -15.0, 15.0));
}

vec3 tanh_approx(vec3 x) {
  return tanh(clamp(x, -15.0, 15.0));
}

// Same formula as smoothstep(), for the calls whose edges are reversed.
float sstep(float e0, float e1, float x) {
  float t = clamp((x-e0)/(e1-e0), 0.0, 1.0);
  return t*t*(3.0-2.0*t);
}

// The audio inputs are replaced by slow sines. This one stood for the bass
// level and bass hits (in 0 to 1); it now breathes gently around a low value.
float beat() {
  return 0.1+0.07*sin(0.7*TIME);
}

// Stood for the spectrum at x (a few bars at the horizon read it). A bar only
// shows above the horizon when this is above 0.625, so the stand-in is a smooth
// hill between 0.68 and 1 that is a little higher at low frequencies and drifts
// slowly, as music would.
float freq(float x,float off) {
  float f = abs(x)+off;
  float w = 0.5+0.25*sin(f*6.0+1.1*TIME)+0.25*sin(f*13.0-0.8*TIME+1.0);
  return 0.68+0.32*w*(0.55+0.45*exp(-0.3*f));
}

// Stood for the waveform (in -1 to 1); only ever scaled down by beat().
float wave(float x) {
  return 0.5*sin(x*10.+0.8*TIME);
}

void rot(thread vec2& p, float a) {
  float
    c=cos(a)
  , s=sin(a)
  ;
  p=vec2(c*p.x+s*p.y,c*p.y-s*p.x);
}

// License: MIT, author: Inigo Quilez, found: https://www.iquilezles.org/www/articles/smin/smin.htm
float pmin(float a, float b, float k) {
  float h = clamp(0.5+0.5*(b-a)/k, 0.0, 1.0);
  return mix(b, a, h) - k*h*(1.0-h);
}

float pmax(float a, float b, float k) {
  return -pmin(-a, -b, k);
}

float rayPlane(vec3 ro, vec3 rd, vec4 p) {
  return -(dot(ro,p.xyz)+p.w)/dot(rd,p.xyz);
}

float length4(vec2 p) {
  p*=p;
  return sqrt(sqrt(dot(p,p)));
}

float segment(vec2 p) {
  float
    d0=length4(p)
  , d1=abs(p.x)
  ;

  return p.y>=0.?d0:d1;
}

// License: MIT, author: Inigo Quilez, found: https://iquilezles.org/articles/distfunctions/
float flatTorus( vec3 p, vec2 t) {
  p=p.xzy;
  vec2 q = vec2(length(p.xz)-t.x,p.y);
  return length4(q)-t.y;
}

// License: MIT, author: Inigo Quilez, found: https://iquilezles.org/articles/distfunctions/
float cappedTorus(vec3 p, vec2 sc, vec2 t) {
  float
    ra = t.x
  , rb = t.y
  ;
  p.x = abs(p.x);
  float k = (sc.y*p.x>sc.x*p.y) ? dot(p.xy,sc) : length(p.xy);
  return sqrt(dot(p,p) + ra*ra - 2.0*ra*k) - rb;
}

// License: MIT, author: Inigo Quilez, found: https://iquilezles.org/articles/distfunctions2d/
float arc(vec2 p, vec2 sc, float ra, float rb) {
  // sc is the sin/cos of the arc's aperture
  p.x = abs(p.x);
  return ((sc.y*p.x>sc.x*p.y) ? length(p-sc*ra) :
                                abs(length(p)-ra)) - rb;
}

const mat3
  roty      = ROTY(radians(10.0))
, rotline   = transpose(roty)*ROTX(0.027)
;

const vec3
  sunDir     = normalize(vec3(0,-0.01, 1))*roty
, lightPos   = vec3(0, -60, -200)*roty
;

vec2 planeCoord(vec3 p, vec3 c, vec3 up, vec4 dim) {
  vec3
    d = p - c
  , xx = (cross(up,dim.xyz))
  , yy = (cross(xx,dim.xyz))
  ;
  return vec2(dot(d,xx), dot(d,yy));
}

// License: MIT, author: Inigo Quilez, found: https://iquilezles.org/www/articles/distfunctions2d/distfunctions2d.htm
float triIso(vec2 p, vec2 q) {
  p.x = abs(p.x);
  vec2 a = p - q*clamp( dot(p,q)/dot(q,q), 0.0, 1.0 );
  vec2 b = p - q*vec2( clamp( p.x/q.x, 0.0, 1.0 ), 1.0 );
  float s = -sign( q.y );
  vec2 d = min( vec2( dot(a,a), s*(p.x*q.y-p.y*q.x) ),
                vec2( dot(b,b), s*(p.y-q.y)  ));
  return -sqrt(d.x)*sign(d.y);
}

// License: MIT, author: Inigo Quilez, found: https://iquilezles.org/articles/intersectors/
vec2 rayBox(vec3 ro, vec3 rd, vec3 boxSize, thread vec3& outNormal)  {
  vec3 m = 1.0/rd; // can precompute if traversing a set of aligned boxes
  vec3 n = m*ro;   // can precompute if traversing a set of aligned boxes
  vec3 k = abs(m)*boxSize;
  vec3 t1 = -n - k;
  vec3 t2 = -n + k;
  float tN = max( max( t1.x, t1.y ), t1.z );
  float tF = min( min( t2.x, t2.y ), t2.z );
  if( tN>tF || tF<0.0) return vec2(-1.0); // no intersection
  outNormal = (tN>0.0) ? step(vec3(tN),t1)  : // ro ouside the box
                         step(t2,vec3(tF))  ;  // ro inside the box
  outNormal *= -sign(rd);
  return vec2( tN, tF );
}

vec3 sky(vec3 ro, vec3 rd) {
  float
    hd = max(abs(rd.y+0.15), 0.00066)
  , i
  ;
  vec3
    col = 0.*sunColor/(1.+1e-5 - dot(sunDir, rd))
  ;

  vec2
    p=vec2(atan(rd.x,rd.z),rd.y+.15)
  , c=p
  , P
  ;
  if (p.y>0.) {
    const float SZ=.05,I=1.;
    float
      n=round(c.x/SZ)
    , d=1e3
    ;
    c.x-=n*SZ;
    for(i=-I;i<=I;++i) {
      P=c;
      P-=vec2(
        i*SZ
      , .2*(freq((n+i)*SZ,SZ))-.25+bar_height
      );
      d=min(d,segment(P)-SZ*.4);
    }

    col+=bar_visibility*1e-3/max(d,1e-3)*(barCol+2.*sqrt(max(0.,-d)));
  }

  col += 1e2*inversesqrt(hd)*glowColor0;
  col += glowColor2/hd;

  return col;
}

vec3 glow(vec3 ro, vec3 rd, float beat) {
  vec3
    bn = vec3(0.0)
  , bro = ro
  ;
  bro.y += -1000.0+70.0;
  vec2
    bi = rayBox(bro, rd, vec3(90.0, 1000.0, 90.0), bn)
  ;
  float
    lightDist = distance(lightPos, ro)
  ;
  vec3
    lightDir  = normalize(lightPos-ro)
  ;
  float
    g3        = 1.+1e-5 - dot(lightDir, rd)
  ;

  vec3
    col = 8.*glowColor0/(g3)
  , rrd = rd*rotline
  ;

  if (any(bi != vec2(-1))) {
    float bdi = tanh_approx(0.00125*(bi.y-bi.x));
    col += 1000.0*glowColor0*(bdi/max(rrd.y, 0.005));
  }

  float sx = abs(rrd.x);
  rrd.y += mix(0.00, 0.0125, beat)*(wave(0.5*sx));
  col += 20.0*glowColor0/(abs(mix(mix(20.0, 0.25, beat)*rrd.y*rrd.y, abs(rrd.y), tanh_approx(4.0*sx)))+mix(2.0, 0.5, beat)*sx*sx*sx+0.0001);

  col *= mix(1.0, 4.0, beat);
  return col;
}

vec3 side(vec3 col, vec3 ro, vec3 rd, float t, vec4 dim, vec3 c) {
  const vec2 tri =vec2(485, sqrt(3.0)*356.0);
  vec3
    n = dim.xyz
  , p = ro + rd*t
  , r = reflect(rd, n)
  , ldiff = p - lightPos
  , ld = normalize(ldiff)
  , rcol0 = sky(p, r)
  ;

  float dcol = max(dot(ld, n), 0.0);
  dcol *= dcol;
  vec2
    pp = planeCoord(p, c, vec3(0, 1, 0), dim)
  , p0 = pp
  , p1 = pp
  ;
  float
    d0 = triIso(p0, tri)
  , d1 = triIso(p1, 0.11*tri)
  , d = d0
  , hf = smoothstep(-600.0, -400.0, p.y)
  ;
  vec3
    bcol = col
  , pcol = 3.0*diffColor*dcol
  ;
  pcol += rcol0;
  pcol = mix(clamp(col, 0.0, 0.1), pcol, hf);
  col = mix(col, pcol, sstep(9., 0., d));
  col += topColor/max(0.00005*(d1-1.), 0.000025)*hf;
  return col;
}

vec3 pyramid(vec3 col, vec3 ro, vec3 rd) {
  float
    t0  = rayPlane(ro, rd , dim0)
  , t1  = rayPlane(ro, rd , dim1)
  ;

  if (t1 > 0.0) {
    col = side(col, ro, rd, t1, dim1, c1);
  }
  if (t0 > 0.0) {
    col = side(col, ro, rd, t0, dim0, c0);
  }


  return col;
}

vec2 g_gd;

// Written for this port (see the note at the top): the bits of the number,
// stirred, as a value from 0 up to 1.
float hash(float co) {
  uint n = as_type<uint>(co + 0.0);      // + 0.0 so that -0.0 and 0.0 agree
  n ^= n >> 15; n *= 0x9E3779B1u;
  n ^= n >> 13; n *= 0x85EBCA77u;
  n ^= n >> 16;
  return float(n >> 8) * (1.0 / 16777216.0);
}

void warpWorld(thread vec3& p){
  vec3
    warp = path(p.z)
  , dwarp = normalize(dpath(p.z))
  , ddwarp = ddpath(p.z)
  ;
  p.xy -= warp.xy;
  p -= dwarp*dot(vec3(p.xy, 0), dwarp)*0.5*vec3(1,1,-1);
  vec2 pxy = p.xy;
  rot(pxy,-50.*ddwarp.x);
  p.xy = pxy;
}

vec2 dfArcs(vec3 p) {
  const vec2
    sc=SCA(PI/16.)
  ;

  vec3
    p1 = p
  ;
  float
    n1 = floor(.25*p1.z+.5)
  , h1 = hash(mod(n1+.125*PERIOD,.25*PERIOD)-.125*PERIOD)
  , sh1 = -1.+2.*h1
  ;
  p1.z-=4.*n1;
  vec3
    p2 = p1
    ;
  vec2 p1xy = p1.xy;
  rot(p1xy,.25*TIME*sh1);
  p1.xy = p1xy;
  p1.xy = abs(p1.xy);
  p1.xy = p1.xy * R45;
  float
    d1 = cappedTorus(p1, sc, vec2(3, 0.225))
  , d2 = flatTorus(p2, vec2(3, .09))
  ;

  return vec2(d1, d2);
}

float df(vec3 p, float t) {
  warpWorld(p);
  vec3 p0 = p;
  p0.y -= 3.0;
  p0.y = -p0.y;
  vec2 dd1 = dfArcs(p);
  float
    d0 = arc(p0.xy, SCA(PI/6.0), 6.0, 0.8)
  , d = d0
  ;
  d = pmax(d, 0.25-dd1.y, 0.125);
  d = min(d, dd1.x);
  d = min(d, dd1.y);
  float gd = dd1.x;
  if (gd<g_gd.x) {
    g_gd=vec2(gd,t);
  }

  return d;
}

float df(vec3 p) {
  return df(p,0.);
}

vec3 normal(vec3 pos) {
  vec2  eps = vec2(NORM_OFF,0.0);
  return normalize(vec3(
    df(pos+eps.xyy) - df(pos-eps.xyy)
  , df(pos+eps.yxy) - df(pos-eps.yxy)
  , df(pos+eps.yyx) - df(pos-eps.yyx)
  ));
}

float rayMarch(vec3 ro, vec3 rd, float initt, thread float& iter) {
  float
    t = initt
  , i
  ;
  for (i = 0.; i < MAX_RAY_MARCHES_HI; ++i) {
    float d = df(ro + rd*t,t);
    if (d < TOLERANCE_HI || t > MAX_RAY_LENGTH_HI) {
      break;
    }
    t += d;
  }
  iter = i;
  return min(t,MAX_RAY_LENGTH_HI);
}


vec3 render0(vec3 ro, vec3 rd, float beat) {
  const
    vec3 ro_ = vec3(0.0, 0.0, -2700.0)*roty
  ;
  const
    mat3 rrd = ROTX(-0.2)
  ;

  rd = rd * rrd;
  ro = ro_;

  vec3
    glowCol = glow(ro, rd, beat)
  , col = sky(ro, rd)
  ;

  col = pyramid(col, ro, rd);
  col += glowCol;
  col=clamp(col,0.,4.);
  return col;
}

vec3 g_X,g_Y,g_Z;

vec3 render1(
    vec3 ro
  , vec3 rd
  , vec2 sp
  , vec2 q
  , thread float& depth
  ) {
  g_gd = vec2(1E3);
  float
    B = beat()
  , iter = 0.
  , t = rayMarch(ro, rd, 0.0, iter)
  , hd
  ;
  vec2
    gd=g_gd
  ;
  hd=smoothstep(0.,0.01,gd.x);
  vec3
    ggcol   = glowCol1/(max(gd.x, 1e-3))
  , skyCol  = render0(ro, rd, B)
  , col     = vec3(0)
  , rcol    = vec3(0)
  ;
  ggcol=clamp(ggcol,0.,4.);

  float
    tt = max(t/MAX_RAY_LENGTH_HI-.3,0.)
  , sfo = 1.-exp(-9.*tt*tt)
  ;
  depth=1e3;
  if (t < MAX_RAY_LENGTH_HI) {
    vec3
      p = ro+rd*t
    , n = normal(p)
    , r = reflect(rd, n)
    ;
    depth = p.z-ro.z;
    float
      fre0 = 1.+dot(rd, n)
    , fre  = fre0
    ;
    fre *= fre;

    float
      dif = max(dot(sunDir, n),0.)
    , ao = 1.0-iter/float(MAX_RAY_MARCHES_HI)
    , fo = mix(0.2, 0.5, ao)
    ;

    vec3 wp = p;
    warpWorld(wp);
    vec2 dd = dfArcs(wp);

    float hit = min(dd.x, dd.y);
    if (hit > .05) {
      g_gd = vec2(1E3);
      float
        riter = 0.
      , rt = rayMarch(p+.1*n, r, 0.3,riter)
      ;
      vec2
        rgd=g_gd
      ;
      vec3 rggcol = 0.5/(max(rgd.x*rgd.x, 1e-3))*(glowCol1);
      rggcol=clamp(rggcol,0.,4.);
      rcol = rggcol;
      rcol *= sstep(0.66, 0.1, tt);
      if (rt < MAX_RAY_LENGTH_HI) {
//        rcol += diffColor*.2;
      } else {
        rcol += .5*render0(p, r, B);
      }
    }
    rcol += 4.0*hd/max(dd.x*dd.x, 0.01)*((diffColor+0.5)*glowCol1);
    col += dif*dif*fo*1e5*(sunColor*diffColor);
    col += fre*rcol;
  }

  col += ggcol;
  col = mix(
      mix(col,col*.25*vec3(2,1,3),sfo)
    , skyCol+hd*sstep(MAX_RAY_LENGTH_HI, MAX_RAY_LENGTH_HI*.5, gd.y)*ggcol
    , sfo
    );


  vec3 rrd = rd*rotline;
  float flash = dot(rrd, normalize(vec3(0.0, -0.2, -1.0)))+1.0005;
  col += smoothstep(.5, 1., B*B)/flash*(0.01*vec3(.5, .25, 1.0));

  return col;
}

// Pass 0 of the original, fpass0(). _uv, _uvc and _xy are rebuilt here.
vec3 fpass0(vec2 fragCoord) {
  vec2
    q = fragCoord/iResolution.xy
  , pp=-1.+2.*q
  , p = 2.*((q-0.5)*vec2(iResolution.x/iResolution.y, 1.0))
  ;

  float
    t=TIME*travel_speed.x
  , z=mod(t, PERIOD)-PERIOD*.5
  , depth = 0.
  ;

  vec3
    ro = path(z)
  , Z  = normalize(dpath(z))
  , dd = ddpath(z)
  , X  = normalize(cross(vec3(0, 1, 0)+10.*dd, Z))
  , Y  = cross(Z,X)
  , rd = normalize(-p.x*X + p.y*Y + 2.*Z)
  , col
  ;
  g_X=X;
  g_Y=Y;
  g_Z=Z;

  col= render1(ro, rd, p, q, depth);

  col -= .025*(.25+length(pp))*vec3(2,3,1);
  col *= sstep(1.5, 0.5, length(pp));

  col = max(col,0.);
  return col;
}

// Pass 1 of the original, fpass1(): the tone mapping.
void mainImage(thread vec4& fragColor, vec2 fragCoord)
{
  vec3 col = fpass0(fragCoord);
  col=clamp(col,0.,9.);
  col=tanh_approx(col);
  col=sqrt(col);
  fragColor = vec4(col, 1);
}
