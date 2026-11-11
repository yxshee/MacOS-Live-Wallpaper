#include <metal_stdlib>
using namespace metal;

// Prepended to every shader scene (Scenes/<id>/main.metal).
//
// A scene file is written the way a Shadertoy shader is: ordinary functions,
// constants and even mutable globals, ending in
//
//     void mainImage(thread vec4& fragColor, vec2 fragCoord)
//
// The app wraps the whole file in a struct (see ShaderScene.swift), so those
// functions become its methods and the globals its fields. That is what lets
// GLSL-style code keep its shape: every function can see iTime and
// iResolution, functions may be used before they are defined, and "globals"
// may be assigned to. See docs/SHADERS.md for the few things that still need
// changing by hand when porting from GLSL.

struct VOut { float4 pos [[position]]; float2 uv; };

struct LWUniforms {
    float4 resolution;      // x, y target pixels; z pixels per point; w aspect (x / y)
    float4 time;            // x seconds of animation; y seconds since the last frame; z frame-rate cap
    float4 date;            // year, month (0-11), day (1-31), seconds since local midnight
    float4 sky;             // real sun elevation (degrees), sun azimuth (degrees), daylight 0-1, moon lit fraction 0-1
    float4 pointer;         // x, y pointer in target pixels; z = 1 when valid
    int4 frame;             // x frame number; y display index; z seed; w flags
    float4 channelRes[2];   // size of the two optional textures, in pixels
};

constexpr sampler lwRepeat(filter::linear, mip_filter::linear, address::repeat);
constexpr sampler lwClamp(filter::linear, mip_filter::linear, address::clamp_to_edge);
constexpr sampler lwNearest(filter::nearest, address::repeat);

vertex VOut lw_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// MARK: GLSL names

typedef float2 vec2;
typedef float3 vec3;
typedef float4 vec4;
typedef int2 ivec2;
typedef int3 ivec3;
typedef int4 ivec4;
typedef uint2 uvec2;
typedef uint3 uvec3;
typedef uint4 uvec4;
typedef bool2 bvec2;
typedef bool3 bvec3;
typedef bool4 bvec4;
typedef float2x2 mat2;
typedef float3x3 mat3;
typedef float4x4 mat4;

// GLSL's mod takes the sign of the divisor (floor), unlike fmod (truncate).
static inline float mod(float x, float y) { return x - y * floor(x / y); }
static inline float2 mod(float2 x, float y) { return x - y * floor(x / y); }
static inline float3 mod(float3 x, float y) { return x - y * floor(x / y); }
static inline float4 mod(float4 x, float y) { return x - y * floor(x / y); }
static inline float2 mod(float2 x, float2 y) { return x - y * floor(x / y); }
static inline float3 mod(float3 x, float3 y) { return x - y * floor(x / y); }
static inline float4 mod(float4 x, float4 y) { return x - y * floor(x / y); }

static inline float atan(float y, float x) { return atan2(y, x); }
static inline float2 atan(float2 y, float2 x) { return atan2(y, x); }
static inline float3 atan(float3 y, float3 x) { return atan2(y, x); }

static inline float inversesqrt(float x) { return rsqrt(x); }
static inline float2 inversesqrt(float2 x) { return rsqrt(x); }
static inline float3 inversesqrt(float3 x) { return rsqrt(x); }

static inline float dFdx(float v) { return dfdx(v); }
static inline float dFdy(float v) { return dfdy(v); }
static inline float2 dFdx(float2 v) { return dfdx(v); }
static inline float2 dFdy(float2 v) { return dfdy(v); }
static inline float3 dFdx(float3 v) { return dfdx(v); }
static inline float3 dFdy(float3 v) { return dfdy(v); }

// Texture lookups. Explicit level 0 by default: these are called from loops
// and branches, where implicit derivatives are undefined.
static inline float4 texture(texture2d<float> t, float2 uv) { return t.sample(lwRepeat, uv, level(0)); }
static inline float4 texture(texture2d<float> t, float2 uv, float bias) { return t.sample(lwRepeat, uv, level(max(bias, 0.0))); }
static inline float4 textureLod(texture2d<float> t, float2 uv, float lod) { return t.sample(lwRepeat, uv, level(lod)); }
static inline float4 texelFetch(texture2d<float> t, int2 p, int lod) {
    return t.read(uint2(p.x, int(t.get_height(lod)) - 1 - p.y), lod);
}
static inline float2 textureSize(texture2d<float> t, int lod) { return float2(t.get_width(lod), t.get_height(lod)); }

static inline float3 lessThan(float3 a, float3 b) { return float3(a < b); }
static inline float3 greaterThan(float3 a, float3 b) { return float3(a > b); }

#define highp
#define mediump
#define lowp
