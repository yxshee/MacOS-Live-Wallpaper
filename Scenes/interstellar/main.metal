// Interstellar
// Hazel Quantock
// This code is licensed under the CC0 license http://creativecommons.org/publicdomain/zero/1.0/
//
// Original: https://www.shadertoy.com/view/Xdl3D2
//
// Ported to Metal Shading Language for MacOS Live Wallpaper.
// Changes from the original:
//  - mainImage's output parameter is declared the Metal way (thread vec4&).
//  - The original reads one random texel per grid cell from Shadertoy's
//    256x256 RGBA noise texture on iChannel0. That texture is not available, so
//    Noise() computes the same kind of value, one independent random vec4 per
//    integer cell, with an integer hash written for this port. Only its .x is
//    used, as in the original. Rand() read the same texture and was never
//    called, so it is left out.
//  - Everything runs on a slowed clock (TIME_SCALE, below, 0.3 of the author's
//    speed) so one surge and stall of the fly-through takes about 42 seconds
//    instead of 12.6, and the fastest streaks do not strobe at a wallpaper's
//    low frame rate.
//  - The divisor of the ray step is kept off zero, because a pixel exactly on
//    the centre of an odd-sized target would otherwise divide 0 by 0.
//  The star field itself (the grid march, the 20 steps, every constant and the
//  colouring) is untouched.

// 1.0 is the author's speed.
#define TIME_SCALE (0.3)

const float tau = 6.28318530717958647692;

// Gamma correction
#define GAMMA (2.2)

vec3 ToLinear( in vec3 col )
{
	// simulate a monitor, converting colour values into light values
	return pow( col, vec3(GAMMA) );
}

vec3 ToGamma( in vec3 col )
{
	// convert back into colour values, so the correct light will come out of the monitor
	return pow( col, vec3(1.0/GAMMA) );
}

// One random vec4 per integer cell (replaces the noise texture lookup).
vec4 Noise( in ivec2 x )
{
	uint n = uint(x.x) * 73856093u ^ uint(x.y) * 19349663u;
	uint4 h = n + uint4(0u, 0x9e3779b9u, 0x3c6ef372u, 0xdaa66d2bu);
	h ^= h >> 16u;
	h *= 0x7feb352du;
	h ^= h >> 15u;
	h *= 0x846ca68bu;
	h ^= h >> 16u;
	return vec4(h >> 8u) * (1.0/16777216.0);
}

void mainImage( thread vec4& fragColor, in vec2 fragCoord )
{
	vec3 ray;
	ray.xy = 2.0*(fragCoord.xy-iResolution.xy*.5)/iResolution.x;
	ray.z = 1.0;

	float offset = iTime*TIME_SCALE*.5;
	float speed2 = (cos(offset)+1.0)*2.0;
	float speed = speed2+.1;
	offset += sin(offset)*.96;
	offset *= 2.0;


	vec3 col = vec3(0);

	vec3 stp = ray/max(max(abs(ray.x),abs(ray.y)),1e-6);

	vec3 pos = 2.0*stp+.5;
	for ( int i=0; i < 20; i++ )
	{
		float z = Noise(ivec2(pos.xy)).x;
		z = fract(z-offset);
		float d = 50.0*z-pos.z;
		float w = pow(max(0.0,1.0-8.0*length(fract(pos.xy)-.5)),2.0);
		vec3 c = max(vec3(0),vec3(1.0-abs(d+speed2*.5)/speed,1.0-abs(d)/speed,1.0-abs(d-speed2*.5)/speed));
		col += 1.5*(1.0-z)*c*w;
		pos += stp;
	}

	fragColor = vec4(ToGamma(col),1.0);
}
