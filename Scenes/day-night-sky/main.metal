// Day and Night Sky (free) by Dimension Almios, MIT licence.
// Put it on a ColorRect that covers the sky and drive `hour` (0 to 24): the
// gradient goes through night, dawn, day and dusk, the sun and the moon travel
// their arc and set behind the horizon line, stars come out at night and puffy
// clouds drift by. The node's modulate tints or fades the whole sky.
// https://godotshaders.com/shader/day-and-night-sky-with-sun-moon-stars-and-clouds/
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the
// original (Godot shading language):
//  - The Godot wrapper is gone (shader_type, fragment(), UV, FRAGCOORD, TIME,
//    COLOR, the node modulate). UV runs top-down as in Godot, so it is rebuilt
//    from our bottom-left fragCoord; fwidth(UV) is just 1 / resolution here.
//  - The exposed uniforms are constants at their defaults, except `hour`,
//    `moon_phase` and the cloud drift, below.
//  - TIME OF DAY: `hour` is replaced by the real sun. The sun's elevation is
//    sin(lwSunElevation), which is exactly what sin(ang) was. Its east-west
//    position (the old cos(ang)) is cos(elevation) * sin(lwSunAzimuth), so the
//    sun rises on the left, climbs along its true path and sets on the right.
//    The moon stays opposite the sun, as in the original. The dawn/dusk palette
//    choice (hour < 12) is a smooth blend on the sun's side of the sky.
//    The sky therefore follows the real day at the user's place.
//  - MOON PHASE: `moon_phase` is driven by lwMoon (the lit fraction). The
//    original shadow disc is kept; only its offset is solved so that the lit
//    part of the disc matches lwMoon, and it is pushed away from the sun's
//    direction (it was always along x) so the lit edge faces the sun. The
//    halo fades with the lit part. The moon's path is unchanged: it stays
//    opposite the sun.
//  - Clouds drift at 0.4 of the original speed (cloud_speed 0.006 instead of
//    0.015), to suit a desktop background. The drift direction is as in the
//    original code (toward the left, although its comment says right).
//  - Only where the result cannot change: the cloud loop is skipped below the
//    horizon line (the clouds are masked out there) and the moon's code is
//    skipped while the moon is under the horizon.
//  - smoothstep() with reversed edges (undefined in Metal) is a helper, sstep();
//    radians() is written out; `far` is renamed `farness`, `lw` is `luma`,
//    and the cloud's `lit` is `lit_c`.
//  - The stars, sun, sky colours and cloud shapes keep the original maths and
//    constants. Stars are in render pixels, as in the original, so the scene
//    is meant to be drawn at scale 1.

#define PI 3.14159265359

#define horizon_y 0.72       // where the horizon line is (fraction of the rect)

#define night_top      vec3(0.03, 0.05, 0.13)
#define night_horizon  vec3(0.17, 0.20, 0.36)
#define dawn_top       vec3(0.25, 0.30, 0.55)
#define dawn_horizon   vec3(1.0, 0.72, 0.55)
#define day_top        vec3(0.30, 0.53, 0.86)
#define day_horizon    vec3(0.84, 0.91, 0.94)
#define dusk_top       vec3(0.22, 0.20, 0.44)
#define dusk_horizon   vec3(0.98, 0.58, 0.40)

#define sun_color  vec3(1.0, 0.96, 0.82)
#define sun_size   0.05      // radius, as a fraction of the rect height
#define moon_color vec3(0.92, 0.94, 1.0)
#define moon_size  0.035
#define glow       1.0       // halo around the sun and the moon
#define arc_height 0.8       // how high they climb (1 = the top of the rect)

#define star_density 0.5
#define twinkle      0.5

#define clouds       0.45    // 0 = no clouds
#define cloud_speed  0.006   // original default 0.015
#define cloud_scale  1.0

float hash(vec2 p) {
	p = fract(p * vec2(0.1031, 0.1030));
	p += dot(p, p.yx + 33.33);
	return fract((p.x + p.y) * p.x);
}

// smoothstep that also works with the edges the other way round
float sstep(float e0, float e1, float x) {
	float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// soft-edged disc, anti-aliased over one pixel
float disc(float r, float radius, float px) {
	return sstep(radius + px, radius - px, r);
}

// Offset of the shadow disc, in moon radii (0 = new moon .. 2 = full), that
// leaves the fraction `lit` of the moon's disc lit. Two equal circles, so the
// shadowed part is a lens; bisection on its area.
float moon_shadow_offset(float lit) {
	float lo = 0.0;
	float hi = 2.0;
	for (int i = 0; i < 7; i++) {
		float m = 0.5 * (lo + hi);
		float lens = 2.0 * acos(0.5 * m) - 0.5 * m * sqrt(4.0 - m * m);
		if (1.0 - lens / PI < lit) lo = m; else hi = m;
	}
	return 0.5 * (lo + hi);
}

void mainImage(thread vec4& fragColor, vec2 fragCoord)
{
	vec2 uv = vec2(fragCoord.x / iResolution.x, 1.0 - fragCoord.y / iResolution.y);   // Godot's UV: origin top left
	vec2 frag = vec2(fragCoord.x, iResolution.y - fragCoord.y);                      // Godot's FRAGCOORD
	float asp = iResolution.x / iResolution.y;             // width / height of the rect
	float px = 1.0 / iResolution.y;                         // one pixel, in UV.y units

	// the sun comes from the real sky: it rises on the left and sets on the
	// right, the moon is opposite it
	float el = lwSunElevation * (PI / 180.0);
	float az = lwSunAzimuth * (PI / 180.0);
	float sun_e = sin(el);                                 // elevation, -1 to 1
	float moon_e = -sun_e;
	float side = cos(el) * sin(az);                        // east (+) to west (-); was cos(ang)
	float arc = horizon_y * arc_height;
	vec2 sun_p = vec2(0.5 - 0.42 * side, horizon_y - sun_e * arc);
	vec2 moon_p = vec2(0.5 + 0.42 * side, horizon_y - moon_e * arc);

	// colours: twilight (dawn on the east side, dusk on the west) around sunrise
	// and sunset; the switch is hidden by the day and night colours
	float am = sstep(-0.2, 0.2, sin(az));
	vec3 tw_top = mix(dusk_top, dawn_top, am);
	vec3 tw_hor = mix(dusk_horizon, dawn_horizon, am);
	float to_day = sstep(0.02, 0.4, sun_e);
	float to_night = sstep(-0.02, -0.3, sun_e);
	vec3 top = mix(mix(tw_top, day_top, to_day), night_top, to_night);
	vec3 hor = mix(mix(tw_hor, day_horizon, to_day), night_horizon, to_night);

	float y = clamp(uv.y / horizon_y, 0.0, 1.0);          // 0 top, 1 horizon
	// flat at the horizon, so the gradient meets the colour below it without a crease
	vec3 c = mix(top, hor, sstep(0.0, 1.0, pow(y, 1.25)));
	float twilight = (1.0 - to_day) * (1.0 - to_night);
	// at sunrise and sunset the horizon glows warmer on the sun's side
	vec2 ds = (uv - sun_p) * vec2(asp, 1.0);
	float rs = length(ds);
	c = mix(c, tw_hor * 1.05, twilight * exp(-rs * 2.5) * sstep(0.4, 1.0, y) * 0.6);

	// sun colour: warmer and deeper near the horizon
	vec3 sun_c = mix(sun_color * vec3(1.0, 0.66, 0.42), sun_color, sstep(0.0, 0.35, sun_e));
	float sun_up = sstep(-0.12, 0.02, sun_e);
	c += sun_c * glow * sun_up * (exp(-rs * 9.0) * 0.3 + exp(-rs * 2.6) * 0.1);

	// stars: one per cell at most, round, anti-aliased, fading toward the horizon
	float night = sstep(0.1, -0.2, sun_e);
	if (star_density > 0.0 && night > 0.0) {
		vec2 p = frag / 9.0;
		vec2 cell = floor(p);
		float h1 = hash(cell);
		if (h1 < star_density * 0.35) {
			vec2 at = vec2(hash(cell + 3.1), hash(cell + 7.7)) * 0.7 + 0.15;
			float rr = length(fract(p) - at) * 9.0;             // screen pixels
			float big = hash(cell + 1.9);
			float size = mix(0.5, 1.3, big * big);
			float star = sstep(size + 0.7, size - 0.3, rr) * mix(0.35, 1.0, big);
			star *= 1.0 - twinkle * 0.6 * (0.5 + 0.5 * sin(iTime * mix(1.5, 3.5, h1 * 3.0) + big * 40.0));
			c += vec3(0.9, 0.93, 1.0) * star * night * (1.0 - sstep(0.35, 0.95, y));
		}
	}

	// moon: halo, then the disc with its shadowed part showing the sky behind
	vec2 dm = (uv - moon_p) * vec2(asp, 1.0);
	float rm = length(dm);
	float moon_up = sstep(-0.12, 0.02, moon_e);
	float lit = clamp(lwMoon, 0.0, 1.0);                    // lit fraction of the moon, from the real sky
	if (moon_e > -0.12) {
		c += moon_color * glow * moon_up * night * mix(0.25, 1.0, lit) * (exp(-rm * 12.0) * 0.22 + exp(-rm * 3.5) * 0.06);
	}

	// sun and moon discs, hidden below the horizon line (the clouds pass in front)
	float hide = sstep(horizon_y + px, horizon_y - px, uv.y);
	float sd = disc(rs, sun_size, px);
	// always a little brighter than its own halo, or it would read as a ring
	vec3 luma = vec3(0.3, 0.59, 0.11);
	float boost = max(1.05, dot(c, luma) / max(dot(sun_c, luma), 1e-3) + 0.08);
	c = mix(c, sun_c * boost, sd * hide);
	if (moon_e > -0.12) {
		float md = disc(rm, moon_size, px);
		// the shadow is a disc of the same size, closer to the centre for a thinner
		// crescent, pushed away from the sun so the lit edge faces it
		vec2 to_sun = (sun_p - moon_p) * vec2(asp, 1.0);
		float sun_dist = length(to_sun);
		vec2 sun_dir = sun_dist > 1e-4 ? to_sun / sun_dist : vec2(-1.0, 0.0);
		vec2 shadow_at = -sun_dir * (moon_shadow_offset(lit) * moon_size);
		float shadow = disc(length(dm - shadow_at), moon_size, px);
		float moon_lit = md * (1.0 - shadow * sstep(1.0, 0.96, lit));   // no shadow at full moon
		vec3 moon_c = moon_color * (0.92 + 0.08 * (1.0 - length(dm) / max(moon_size, 1e-4)));
		c = mix(c, max(c, moon_c), moon_lit * hide * mix(0.35, 1.0, night));
	}

	// clouds: flat-bottomed puffy clouds drifting in a band of the sky, lit from
	// above and coloured by the hour. Each one is a few round puffs that swell and
	// shrink slowly, so the clouds change shape as they go.
	if (clouds > 0.0 && uv.y < horizon_y) {
		float cw = 0.34 * cloud_scale;                      // one cloud slot, in rect heights
		float x = uv.x * asp + iTime * cloud_speed * 2.0;
		float id = floor(x / cw);
		float dist = 10.0;
		float base = 0.0;
		float size = 1.0;
		for (int j = -1; j <= 1; j++) {
			float cid = id + float(j);
			if (hash(vec2(cid, 1.7)) > clouds * 1.5) continue;
			float farness = hash(vec2(cid, 5.3));               // 0 high and near .. 1 low and far
			float sz = cw * mix(0.2, 0.11, farness);           // puff radius
			vec2 cc = vec2((cid + 0.5 + (hash(vec2(cid, 2.9)) - 0.5) * 0.4) * cw,
				horizon_y * mix(0.18, 0.62, farness));
			float len = mix(0.8, 1.5, hash(vec2(cid, 8.1)));    // longer or rounder clouds
			float bottom = cc.y + sz * 0.45;
			// a rounded body along the bottom joins the puffs
			vec2 bq = abs(vec2(x, uv.y) - vec2(cc.x, bottom - sz * 0.32)) - vec2(sz * 1.05 * len, 0.0);
			float d = length(max(bq, 0.0)) - sz * 0.32;
			for (int k = 0; k < 4; k++) {
				float fk = float(k);
				float ox = (fk - 1.5) * sz * 0.62 * len;
				float r = sz * mix(0.62, 1.05, hash(vec2(cid, fk + 11.0))) * (1.0 - 0.3 * abs(fk - 1.5) / 1.5);
				r *= 1.0 + 0.07 * sin(iTime * 0.35 + fk * 2.1 + cid * 5.0);
				vec2 q = vec2(x, uv.y) - vec2(cc.x + ox, bottom - r * 0.72);
				d = min(d, length(q) - r);
			}
			d = max(d, uv.y - bottom);                             // flat bottom
			if (d < dist) {
				dist = d;
				base = bottom;
				size = sz;
			}
		}
		float cov = sstep(px, -px, dist);
		if (cov > 0.0) {
			// light from above: the lower part of each cloud is in its own shade
			float lit_c = 1.0 - sstep(base - size * 0.9, base - size * 0.05, uv.y) * 0.55;
			vec3 light = mix(hor, vec3(1.0), 0.6 * (1.0 - to_night)) * mix(1.0, 0.8, to_night);
			light += sun_c * sun_up * exp(-rs * 3.0) * 0.35;
			vec3 shade = mix(mix(top, hor, 0.5), light, 0.35) * mix(0.95, 0.8, to_night);
			c = mix(c, mix(shade, light, lit_c), cov * sstep(0.0, 0.03, horizon_y - uv.y));
		}
	}

	c += (hash(frag + fract(iTime * 7.0) * 61.0) - 0.5) / 255.0 * 1.5;   // dither: no banding
	fragColor = vec4(c, 1.0);
}
