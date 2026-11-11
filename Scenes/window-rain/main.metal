/*
	動的窓の雨 水滴シェーダー for Godot Engine by あるる（きのもと 結衣） @arlez80
	Procedural Window Raindrop Shader by Yui Kinomoto @arlez80

	MIT License
*/
// https://godotshaders.com/shader/procedural-window-rain-drop-shader/
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the
// original:
//  - The Godot wrapper (shader_type spatial, fragment(), UV, TIME, SCREEN_TEXTURE,
//    SCREEN_UV, ALBEDO, NORMALMAP) is gone. The drop maths runs in mainImage. UV
//    keeps Godot's orientation (origin top left, y down) and is the window pane's
//    height-normalised coordinate: x is divided by the screen height too, so the
//    drops keep their shape on a portrait, a laptop or an ultrawide screen.
//  - The uniforms are constants at their default values, except dripping_speed:
//    1.0 -> 0.17, so a streak takes about 24 seconds to cross the screen.
//  - TIME enters only through mod(., 1.0), so it is wrapped with fract(): the same
//    picture, without losing precision after days of uptime.
//  - float(length(v) < r) became a one pixel wide coverage ramp (anti-aliasing);
//    the unused PI constant was dropped.
//  - ADDED BY THE PORT (not the author's): in Godot the engine lit the pane from
//    NORMALMAP over the screen texture. Here the same normal (decoded the way
//    Godot decodes NORMALMAP) is used for a fixed light, a Blinn-Phong highlight and
//    a simple refraction, and the "screen texture" is a procedural night-city
//    bokeh background (wrBackground and its helpers below) that drifts and
//    twinkles very gently, sharper and smaller inside the drops than on the misted
//    glass. A tiny dither hides banding in the dark gradient.

// ---------------------------------------------------------------------------
// The author's drop pattern
// ---------------------------------------------------------------------------

vec2 distance_line_point( vec2 a, vec2 b, vec2 p )
{
	vec2 v = b - a;
	vec2 vp = p - a;
	float r = clamp( dot( v, vp ) / dot( v, v ), 0.0, 1.0 );

	return mix(
		a - p
	,	b - p
	,	r
	);
}

// ---------------------------------------------------------------------------
// ADDED BY THE PORT: procedural night-city bokeh to refract
// ---------------------------------------------------------------------------

uint wrFmix( uint h )
{
	h ^= h >> 16; h *= 0x85ebca6bu;
	h ^= h >> 13; h *= 0xc2b2ae35u;
	h ^= h >> 16;
	return h;
}

uint wrCell( int2 c, int seed )
{
	uint h = wrFmix( uint( c.x ) + 0x9e3779b9u );
	h = wrFmix( h ^ ( uint( c.y ) + 0x7f4a7c15u ) );
	return wrFmix( h + uint( seed ) * 0x632be5abu );
}

float wrRand( uint h, uint k )
{
	return float( wrFmix( h + k * 0x9e3779b1u ) >> 8 ) * ( 1.0 / 16777216.0 );
}

vec3 wrLampColour( float t )
{
	if( t < 0.30 ) return vec3( 1.00, 0.60, 0.26 );   // sodium amber
	if( t < 0.52 ) return vec3( 1.00, 0.80, 0.52 );   // warm window light
	if( t < 0.68 ) return vec3( 0.58, 0.74, 1.00 );   // cool white
	if( t < 0.80 ) return vec3( 1.00, 0.32, 0.52 );   // pink neon
	if( t < 0.91 ) return vec3( 0.22, 0.88, 0.80 );   // teal sign
	return vec3( 0.55, 1.00, 0.45 );                   // green signal
}

// One layer of out-of-focus lights. p is in screen heights (y up); blur is 1 on the
// misted glass and falls towards 0 inside a drop, where the lights are smaller,
// sharper and brighter.
vec3 wrBokehLayer( vec2 p, float cell, float rmin, float rmax, float gain, float density, float blur, int seed )
{
	vec2 q = p / cell;
	int2 base = int2( floor( q ) );
	vec3 acc = vec3( 0.0 );

	for( int j = -1; j <= 1; j++ ) {
		for( int i = -1; i <= 1; i++ ) {
			int2 c = base + int2( i, j );
			uint h = wrCell( c, seed );
			float ypos = ( float( c.y ) + 0.5 ) * cell;
			float env = 0.22 + 0.78 * smoothstep( 0.90, 0.28, ypos );   // lights gather low, like a skyline
			if( wrRand( h, 1u ) > density * env ) continue;

			vec2 centre = ( vec2( c ) + 0.2 + 0.6 * vec2( wrRand( h, 2u ), wrRand( h, 3u ) ) ) * cell;
			float r = mix( rmin, rmax, wrRand( h, 4u ) ) * mix( 0.62, 1.0, blur );
			float e = r * mix( 0.12, 0.55, blur );
			float d = length( p - centre );
			float disc = smoothstep( r + e, r - e, d );
			float tw = 0.82 + 0.18 * sin( iTime * ( 0.25 + 0.5 * wrRand( h, 5u ) ) + 6.2831 * wrRand( h, 6u ) );
			float amp = gain * tw * mix( 1.9, 1.0, blur ) * mix( 0.55, 1.0, wrRand( h, 7u ) );
			acc += wrLampColour( wrRand( h, 8u ) ) * ( disc * amp );
		}
	}
	return acc;
}

// p: screen position in heights, y up.
vec3 wrBackground( vec2 p, float blur )
{
	// dark gradient with a faint warm skyline glow
	vec3 col = mix( vec3( 0.078, 0.040, 0.052 ), vec3( 0.010, 0.018, 0.046 ), smoothstep( 0.0, 1.05, p.y ) );
	float band = ( p.y - 0.36 ) / 0.24;
	col += vec3( 0.060, 0.032, 0.034 ) * exp( -band * band );

	// slow drift, a little faster for the nearer layers
	col += wrBokehLayer( p + vec2( iTime * 0.0012, 0.0 ), 0.32, 0.070, 0.130, 0.24, 0.62, blur, 11 );
	col += wrBokehLayer( p + vec2( iTime * 0.0021, 0.0 ), 0.18, 0.035, 0.070, 0.36, 0.60, blur, 23 );
	col += wrBokehLayer( p + vec2( iTime * 0.0030, 0.0 ), 0.10, 0.015, 0.035, 0.55, 0.55, blur, 37 );
	return col;
}

// ---------------------------------------------------------------------------

void mainImage( thread vec4& fragColor, in vec2 fragCoord )
{
	// the author's uniforms, at their defaults (dripping_speed slowed, see above)
	const float dripping_speed = 0.17;
	const vec2 dripping_wave_size = vec2( 20.0, 4.0 );
	const vec2 dripping_wave_freq = vec2( 47.0, 15.0 );
	const vec2 dripping_wave_power = vec2( 0.045, 1.0 );

	const float static_interval = 10.0;
	const vec2 static_shift = vec2( 4.8, 0.8 );
	const vec2 static_wave_size = vec2( 81.432143, 85.45453 );
	const vec2 static_wave_freq = vec2( 38.0, 92.0 );
	const vec2 static_wave_power = vec2( 1.8, 2.8 );

	// Godot's UV (origin top left) in screen heights; p is the same place with y up
	vec2 p = fragCoord / iResolution.y;
	vec2 UV = vec2( p.x, 1.0 - p.y );

	vec2 uv_drip = UV * dripping_wave_size + vec2( cos( UV.y * dripping_wave_freq.x ), sin( UV.x * dripping_wave_freq.y ) ) * dripping_wave_power + vec2( 0.0, -fract( iTime * dripping_speed ) );
	vec2 n = vec2( 0.5, 0.5 );

	// 動的雨粒
	vec2 pd = mod( uv_drip, 1.0 );
	vec2 v = distance_line_point( vec2( 0.5, 0.2 ), vec2( 0.5, 0.8 ), pd );
	float lv = length( v );
	float rad = pd.y * 0.1;
	vec2 fd = abs( dFdx( uv_drip ) ) + abs( dFdy( uv_drip ) );                 // pixel footprint in cell units
	float gd = dot( abs( v ), fd ) / max( lv, 1e-4 ) + 0.1 * fd.y;
	float cd = clamp( 0.5 + ( rad - lv ) / max( gd, 1e-6 ), 0.0, 1.0 );        // was float( length( v ) < rad )
	n = mix( n, n - v * 10.0, cd );

	// 静的雨粒
	vec2 uv_static = static_shift + UV * static_wave_size + vec2( sin( cos( UV.y * static_wave_freq.x ) ), cos( sin( UV.x ) * static_wave_freq.y ) ) * static_wave_power;
	vec2 sv = mod( uv_static, static_interval ) - vec2( 0.5, 0.5 );
	float ls = length( sv );
	vec2 fs = abs( dFdx( uv_static ) ) + abs( dFdy( uv_static ) );
	float gs = dot( abs( sv ), fs ) / max( ls, 1e-4 );
	float cs = clamp( 0.5 + ( 0.5 - ls ) / max( gs, 1e-6 ), 0.0, 1.0 );       // was float( length( sv ) < 0.5 )
	n = mix( n, n + sv, cs );

	vec3 nv = normalize( vec3( n, 1.0 ) );

	// ---- ADDED BY THE PORT from here: what Godot's lighting and the screen texture did ----

	// Godot decodes NORMALMAP as an encoded normal; do the same, and take the flat pane as reference
	vec2 nxy = nv.xy * 2.0 - 1.0;
	vec3 N = normalize( vec3( nxy, sqrt( max( 0.0, 1.0 - dot( nxy, nxy ) ) ) ) );
	vec3 nf = normalize( vec3( 0.5, 0.5, 1.0 ) );
	vec2 fxy = nf.xy * 2.0 - 1.0;
	vec3 Nf = normalize( vec3( fxy, sqrt( max( 0.0, 1.0 - dot( fxy, fxy ) ) ) ) );

	// refraction: the drop bends the view by its slope (UV's y points down, so flip it)
	vec2 slope = N.xy - Nf.xy;
	vec2 refr = vec2( -slope.x, slope.y ) * 0.045;

	float drop = max( cd, cs );
	vec3 col = wrBackground( p + refr, 1.0 - 0.78 * drop );

	// fixed light from the upper left (in UV's frame, y down)
	vec3 L = normalize( vec3( -0.55, -0.50, 0.62 ) );
	vec3 H = normalize( L + vec3( 0.0, 0.0, 1.0 ) );
	float shade = ( max( dot( N, L ), 0.0 ) + 0.35 ) / ( max( dot( Nf, L ), 0.0 ) + 0.35 );
	float spec = max( pow( max( dot( N, H ), 0.0 ), 70.0 ) - pow( max( dot( Nf, H ), 0.0 ), 70.0 ), 0.0 );
	col = col * clamp( shade, 0.38, 1.5 ) + vec3( 0.80, 0.90, 1.00 ) * ( spec * 0.85 );

	// gentle tone curve, then a half-step of dither against banding in the dark gradient
	col = 1.0 - exp( -col * 1.35 );
	uint hd = wrCell( int2( fragCoord ), 91 );
	col += ( float( hd >> 8 ) * ( 1.0 / 16777216.0 ) - 0.5 ) * ( 1.0 / 255.0 );

	fragColor = vec4( col, 1.0 );
}
