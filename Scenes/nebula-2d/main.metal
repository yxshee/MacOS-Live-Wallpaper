// 2d Nebula Shader by flytrap
// https://godotshaders.com/shader/2d-nebula-shader/
// The shader code on that page is published under CC0 1.0:
// "The shader code and all code snippets in this post are under CC0 license
// and can be used freely without the author's permission."
//
// Author's note: "I am still a beginner at shading, but I tried to put
// together something pretty. Stars rendered using
// https://godotshaders.com/shader/stars-shader/ by gerardogc2378 (also CC0).
// Using FBM on perlin noise to generate clouds, and parallax scrolling
// through in a circle."
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the
// original (Godot 3 canvas_item shader):
//  - The Godot wrapper (shader_type, uniform, fragment(), UV, TIME, COLOR) is
//    removed; the exposed uniforms are constants at their default values.
//  - UV is rebuilt from fragCoord: origin at the top left as in Godot, and the
//    shorter side of the screen spans 0..1 so the picture is not stretched.
//  - Slowed for a desktop background. The original scrolls the clouds by
//    0.03*T*sin(0.07*T) with T = 5*TIME, so the offset (and the speed) grows
//    without limit as time passes. Here T = 0.25*TIME and the growing factor
//    T is replaced by a constant (DRIFT_RADIUS = 100, what the original has
//    after 20 seconds), so the clouds drift on a slow bounded loop instead.
//    The cloud "tide" and the star twinkle use the same slowed clock
//    (BREATH = 0.25 instead of 1.0).
//  - The final colour is clamped to 0..1, as Godot's 8-bit framebuffer does.
//  - The star spikes divide by the distance to the star's centre lines; that
//    distance is kept at 0.0001 or more so no pixel divides by zero.
//  - The unused fbm() function and the unused texture lookup are dropped. The
//    alpha channel is still carried but, as in the original, never output.
//  - The constants size, prob, zoomScale and starscale are renamed (STAR_SIZE,
//    STAR_PROB, ZOOM_SCALE, STAR_SCALE) so they cannot clash with other names.

#define OCTAVE 12
#define TIMESCALE 0.25
#define BREATH 0.25
#define DRIFT_RADIUS 100.0

#define CLOUD1_COL vec4(0.41, 0.64, 0.78, 0.4)
#define CLOUD2_COL vec4(0.99, 0.79, 0.46, 0.2)
#define CLOUD3_COL vec4(0.81, 0.31, 0.59, 1.0)
#define CLOUD4_COL vec4(0.27, 0.15, 0.33, 1.0)
#define SPACE      vec4(0.09, 0.06, 0.28, 0.3)

#define ZOOM_SCALE 6.0
#define STAR_SIZE      10.0
#define STAR_SCALE 20.0
#define STAR_PROB      0.98

float rand(vec2 p) {
	return fract(sin(dot(p, vec2(23.53, 44.0))) * 42350.45);
}

float perlin(vec2 p) {
	vec2 i = floor(p);
	vec2 j = fract(p);
	vec2 coord = smoothstep(vec2(0.), vec2(1.), j);
	float a = rand(i);
	float b = rand(i + vec2(1.0, 0.0));
	float c = rand(i + vec2(0.0, 1.0));
	float d = rand(i + vec2(1.0, 1.0));
	return mix(mix(a, b, coord.x), mix(c, d, coord.x), coord.y);
}

float fbmCloud(vec2 p, float minimum) {
	float value = 0.0;
	float scale = 0.5;
	for (int i = 0; i < OCTAVE; i++) {
		value += perlin(p) * scale;
		p *= 2.0;
		scale *= 0.5;
	}
	return smoothstep(0., 1., (smoothstep(minimum, 1., value) - minimum) / (1.0 - minimum));
}

float fbmCloud2(vec2 p, float minimum) {
	float value = 0.0;
	float scale = 0.5;
	for (int i = 0; i < OCTAVE; i++) {
		value += perlin(p) * scale;
		p *= 2.0;
		scale *= 0.5;
	}
	return (smoothstep(minimum, 1., value) - minimum) / (1.0 - minimum);
}

void mainImage(thread vec4& fragColor, vec2 fragCoord)
{
	// Godot's UV: origin top left, the short side spans 0..1.
	vec2 UV = vec2(fragCoord.x, iResolution.y - fragCoord.y) / min(iResolution.x, iResolution.y);

	float timescaled = iTime * TIMESCALE;
	float breath = iTime * BREATH;
	float R = DRIFT_RADIUS;
	vec2 zoomUV2 = vec2(ZOOM_SCALE * UV.x + 0.03  * R * sin(0.07 * timescaled), ZOOM_SCALE * UV.y + 0.03  * R * cos(0.06 * timescaled));
	vec2 zoomUV3 = vec2(ZOOM_SCALE * UV.x + 0.027 * R * sin(0.07 * timescaled), ZOOM_SCALE * UV.y + 0.025 * R * cos(0.06 * timescaled));
	vec2 zoomUV4 = vec2(ZOOM_SCALE * UV.x + 0.021 * R * sin(0.07 * timescaled), ZOOM_SCALE * UV.y + 0.021 * R * cos(0.07 * timescaled));
	float tide  = 0.05 * sin(breath);
	float tide2 = 0.06 * cos(0.3 * breath);

	vec4 nebulaTexture = vec4(SPACE.rgb, 0.5 + 0.2 * sin(0.23 * breath + UV.x - UV.y));
	nebulaTexture += fbmCloud2(zoomUV3, 0.24 + tide) * CLOUD1_COL;
	nebulaTexture += fbmCloud(zoomUV2 * 0.9, 0.33 - tide) * CLOUD2_COL;
	nebulaTexture = mix(nebulaTexture, CLOUD3_COL, fbmCloud(vec2(0.9 * zoomUV4.x, 0.9 * zoomUV4.y), 0.25 + tide2));
	nebulaTexture = mix(nebulaTexture, CLOUD4_COL, fbmCloud(zoomUV3 * 0.7 + 2.0, 0.4 + tide2));

	vec2 zoomstar = STAR_SCALE * zoomUV2;
	vec2 pos = floor(zoomstar / STAR_SIZE);
	float starValue = rand(pos);
	if (starValue > STAR_PROB) {
		vec2 center = STAR_SIZE * pos + vec2(STAR_SIZE, STAR_SIZE) * 0.5;
		float t = 0.9 + 0.2 * sin(breath * 8.0 + (starValue - STAR_PROB) / (1.0 - STAR_PROB) * 45.0);
		float color = 1.0 - distance(zoomstar, center) / (0.5 * STAR_SIZE);
		float dy = max(abs(zoomstar.y - center.y), 0.0001);
		float dx = max(abs(zoomstar.x - center.x), 0.0001);
		nebulaTexture = mix(nebulaTexture, vec4(1.0, 1.0, 1.0, 1.0), smoothstep(0., 1., color * t / dy * t / dx));
	} else {
		zoomstar *= 5.0;
		pos = floor(zoomstar / STAR_SIZE);
		float starValue2 = rand(pos + vec2(13.0, 13.0));
		if (starValue2 >= 0.95) {
			vec2 center = STAR_SIZE * pos + vec2(STAR_SIZE, STAR_SIZE) * 0.5;
			float t = 0.9 + 0.2 * sin(breath * 8.0 + (starValue - STAR_PROB) / (1.0 - STAR_PROB) * 45.0);
			float color = 1.0 - distance(zoomstar, center) / (0.5 * STAR_SIZE);
			float dy = max(abs(zoomstar.y - center.y), 0.0001);
			float dx = max(abs(zoomstar.x - center.x), 0.0001);
			nebulaTexture = mix(nebulaTexture, vec4(1.0, 1.0, 1.0, 1.0), fbmCloud(pos, 0.0) * smoothstep(0., 1., color * t / dy * t / dx));
		}
	}

	fragColor = vec4(clamp(nebulaTexture.rgb, 0.0, 1.0), 1.0);
}
