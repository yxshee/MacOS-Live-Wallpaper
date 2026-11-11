/*--------------------------------------------------------------------------------------
License CC0 - http://creativecommons.org/publicdomain/zero/1.0/
To the extent possible under law, the author(s) have dedicated all copyright and related and neighboring rights to this software to the public domain worldwide. This software is distributed without any warranty.
----------------------------------------------------------------------------------------
^ This means do ANYTHING YOU WANT with this code. Because we are programmers, not lawyers.
-Otavio Good
*/

// Iceberg by Otavio Good
// https://github.com/libretro/glsl-shaders/blob/master/procedural/otaviogood-iceberg.glsl
//
// Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the
// original:
//  - The libretro wrapper (vertex shader, uniforms, parameter pragma, main())
//    is removed; time comes from iTime, size from iResolution.
//  - Time runs at half the libretro speed (timeScale below; the libretro
//    wrapper ran it at 1.5 times), so the camera drifts calmly.
//  - The "fade" value the author computes for each camera shot, whose use was
//    commented out at the end of RayTrace, is switched on, so the three shots
//    dissolve through black instead of cutting.
//  - Out parameters of TraceOneRay are written thread T&.
//  - The locals named cos and sin in RotateX/Y/Z are renamed (they shadow the
//    functions in Metal).
//  - Variables are initialised, as Metal does not zero them.
//  - The author's disabled options (NON_REALTIME_HQ_RENDER, MANUAL_CAMERA,
//    HQ_NOISE and the block renderer behind them) are removed. The camera
//    animation, constants and shading are untouched.
//  - Speed-ups that leave the picture unchanged (marked "Port:" below), added
//    so the scene fits the wallpaper's GPU budget. Against the plain port,
//    fewer than 0.02% of pixels differ by more than 2/255:
//      * DistanceToObject skips the iceberg's distance where a cheap bound
//        proves the water is the nearer surface and the iceberg cannot
//        change the result.
//      * The ray march steps by the iceberg's bound, not the height above
//        the water, for rays that are rising and cannot hit the water.
//      * The ambient-occlusion samples (read only by the water) and the
//        scattering loop (read only by the iceberg) are computed only for
//        the material that uses them.
//      * The camera ray and the water-reflection ray share one call of
//        TraceOneRay, in a two-pass loop.

// Animation speed: 1.0 is Shadertoy speed. The libretro wrapper used 1.5.
const float timeScale = 0.5;

// --------------------------------------------------------
float localTime = 0.0;

// Animation variables
float fade = 1.0;
float exposure = 1.0;

// lighting vars
vec3 sunDir = normalize(vec3(0.93, 1.0, 1.0));
const vec3 sunCol = vec3(250.0, 220.0, 200.0) / 3555.0;
const vec3 horizonCol = vec3(0.95, 0.95, 0.95)*1.3;
const vec3 skyCol = vec3(0.03,0.45,0.95);
const vec3 groundCol = vec3(0.003,0.7,0.75);

// ---- noise functions ----
float v31(vec3 a)
{
    return a.x + a.y * 37.0 + a.z * 521.0;
}
float v21(vec2 a)
{
    return a.x + a.y * 37.0;
}
float Hash11(float a)
{
    return fract(sin(a)*10403.9);
}
float Hash21(vec2 uv)
{
    float f = uv.x + uv.y * 37.0;
    return fract(sin(f)*104003.9);
}
vec2 Hash22(vec2 uv)
{
    float f = uv.x + uv.y * 37.0;
    return fract(cos(f)*vec2(10003.579, 37049.7));
}
vec2 Hash12(float f)
{
    return fract(cos(f)*vec2(10003.579, 37049.7));
}
// noise functions
float Hash2d(vec2 uv)
{
    float f = uv.x + uv.y * 37.0;
    return fract(sin(f)*104003.9);
}
float Hash3d(vec3 uv)
{
    float f = uv.x + uv.y * 37.0 + uv.z * 521.0;
    return fract(sin(f)*110003.9);
}
float mixP(float f0, float f1, float a)
{
    return mix(f0, f1, a*a*(3.0-2.0*a));
}
const vec2 zeroOne = vec2(0.0, 1.0);
float noise1d(float uv)
{
    float fr = fract(uv);
    float fl = floor(uv);
    float h0 = Hash11(fl);
    float h1 = Hash11(fl + 1.0);
    return mixP(h0, h1, fr);
}
float noise2d(vec2 uv)
{
    vec2 fr = fract(uv.xy);
    vec2 fl = floor(uv.xy);
    float h00 = Hash2d(fl);
    float h10 = Hash2d(fl + zeroOne.yx);
    float h01 = Hash2d(fl + zeroOne);
    float h11 = Hash2d(fl + zeroOne.yy);
    return mixP(mixP(h00, h10, fr.x), mixP(h01, h11, fr.x), fr.y);
}
float noiseValue(vec3 uv)
{
    vec3 fr = fract(uv.xyz);
    vec3 fl = floor(uv.xyz);
    float h000 = Hash3d(fl);
    float h100 = Hash3d(fl + zeroOne.yxx);
    float h010 = Hash3d(fl + zeroOne.xyx);
    float h110 = Hash3d(fl + zeroOne.yyx);
    float h001 = Hash3d(fl + zeroOne.xxy);
    float h101 = Hash3d(fl + zeroOne.yxy);
    float h011 = Hash3d(fl + zeroOne.xyy);
    float h111 = Hash3d(fl + zeroOne.yyy);
    return mixP(
        mixP(mixP(h000, h100, fr.x),
             mixP(h010, h110, fr.x), fr.y),
        mixP(mixP(h001, h101, fr.x),
             mixP(h011, h111, fr.x), fr.y)
        , fr.z);
}


const float PI=3.14159265;

vec3 saturate(vec3 a) { return clamp(a, 0.0, 1.0); }
vec2 saturate(vec2 a) { return clamp(a, 0.0, 1.0); }
float saturate(float a) { return clamp(a, 0.0, 1.0); }

vec3 RotateX(vec3 v, float rad)
{
  float c = cos(rad);
  float s = sin(rad);
  return vec3(v.x, c * v.y + s * v.z, -s * v.y + c * v.z);
}
vec3 RotateY(vec3 v, float rad)
{
  float c = cos(rad);
  float s = sin(rad);
  return vec3(c * v.x - s * v.z, v.y, s * v.x + c * v.z);
}
vec3 RotateZ(vec3 v, float rad)
{
  float c = cos(rad);
  float s = sin(rad);
  return vec3(c * v.x + s * v.y, -s * v.x + c * v.y, v.z);
}

// This function basically is a procedural environment map that makes the sun
vec3 GetSunColorSmall(vec3 rayDir, vec3 sunDir)
{
	vec3 localRay = normalize(rayDir);
	float dist = 1.0 - (dot(localRay, sunDir) * 0.5 + 0.5);
	float sunIntensity = 0.05 / dist;
    sunIntensity += exp(-dist*150.0)*7000.0;
	sunIntensity = min(sunIntensity, 40000.0);
	return sunCol * sunIntensity*0.2;
}

vec3 GetEnvMap(vec3 rayDir, vec3 sunDir)
{
    // fade the sky color, multiply sunset dimming
    vec3 finalColor = mix(horizonCol, skyCol, pow(saturate(rayDir.y), 0.47))*0.95;
    // make clouds - just a horizontal plane with noise
    float n = noise2d(rayDir.xz/rayDir.y*1.0);
    n += noise2d(rayDir.xz/rayDir.y*2.0)*0.5;
    n += noise2d(rayDir.xz/rayDir.y*4.0)*0.25;
    n += noise2d(rayDir.xz/rayDir.y*8.0)*0.125;
    n = pow(abs(n), 3.0);
    n = mix(n * 0.2, n, saturate(abs(rayDir.y * 8.0)));  // fade clouds in distance
    finalColor = mix(finalColor, (vec3(1.0)+sunCol*10.0)*0.75*saturate((rayDir.y+0.2)*5.0), saturate(n*0.125));

    // add the sun
    finalColor += GetSunColorSmall(rayDir, sunDir);
    return finalColor;
}

// min function that supports materials in the y component
vec2 matmin(vec2 a, vec2 b)
{
    if (a.x < b.x) return a;
    else return b;
}

// ---- shapes defined by distance fields ----
// See this site for a reference to more distance functions...
// http://iquilezles.org/www/articles/distfunctions/distfunctions.htm

// signed box distance field
float sdBox(vec3 p, vec3 radius)
{
  vec3 dist = abs(p) - radius;
  return min(max(dist.x, max(dist.y, dist.z)), 0.0) + length(max(dist, 0.0));
}

float cyl(vec3 p, float rad)
{
    return length(p.xy) - rad;
}

float sSphere(vec3 p, float rad)
{
    return length(p) - rad;
}

// k should be negative. -4.0 works nicely.
// smooth blending function
float smin(float a, float b, float k)
{
	return log2(exp2(k*a)+exp2(k*b))/k;
}

const float sway = 0.015;

// This is the distance function that defines all the scene's geometry.
// The input is a position in space.
// The output is the distance to the nearest surface, a material index,
// and the difference between the iceberg distance and the water distance.
vec3 DistanceToObject(vec3 p)
{
    float dist = p.y;

    if (abs(dist) < 0.07)  // Only calculate noise if we are close.
    {
        // Sum up different frequencies of noise to make water waves.
        float waterNoise = noise2d(p.xz*4.0+localTime)*0.1 +
            noise2d(p.xz*8.0+localTime)*0.03 +
            noise2d(p.xz*16.0-localTime)*0.015 +
            noise2d(p.xz*32.0-localTime)*0.005 +
            noise2d(p.xz*64.0-localTime)*0.002;
        // Fade the waves a bit in the distance.
    	dist += waterNoise * 0.2 * saturate(8.0/length(p.xz));
    }
    vec2 water = vec2(dist, 1.0);

    // Port: skip the iceberg when it provably cannot matter here. Everything
    // the iceberg adds to its sculpted distance (the noise terms) is >= 0, the
    // two smooth blends are slack by at most 0.2 and 1/30, and the tiny sway
    // rotation moves the big sphere's centre by under 0.2. So the distance to
    // the iceberg is at least iceLB below. When that is 0.3 more than the
    // water's distance, the nearer surface is the water and the result below
    // is unchanged: the water wins the min, and the third component only
    // feeds saturating terms (|z| * 3.5 and so on), which a large negative
    // value saturates exactly as the true one would.
    float iceLB = min(length(p) - 2.325, length(p - vec3(-1.0, -11.85, 0.0)) - 12.4);
    if (iceLB > water.x + 0.3) return vec3(water.x, 1.0, -1000.0);

    p = RotateZ(p, sin(localTime)*sway);
    // Sculpt the iceberg.
    float slant = (p.y + p.x*0.25) / 1.0307;
    slant -= cos(p.z*2.0)*0.0625;
    dist = sSphere(p, 2.0) + sin(p.z*4.0)*0.125;
    dist = smin(dist, sSphere(p + vec3(1.0, 11.85, 0.0), 12.0), -5.0);
    float chop = cyl(p.xzy + vec3(1.5), 1.5);
    float chop2 = cyl(p.xyz + vec3(0.0, -0.5, 0.0), 0.6) + sin(p.z*2.0)*0.125;
    chop2 = min(chop2, -slant + 1.6);
    chop2 = min(chop2, sdBox(p + vec3(-1.75, -0.74, -2.0), vec3(0.7)));
    chop = smin(chop, chop2, -10.0);
    chop = min(chop, chop2);
    dist = -smin(-dist, chop, -30.0);
    if (abs(dist) < 0.5)  // Only calculate noise if we are close.
    {
    	dist += noiseValue(vec3(slant)*4.0)*0.1 + noiseValue(vec3(slant)*8.0)*0.05;
        float snowNoise=0.0;
   		snowNoise = noiseValue(p*4.0)*0.5*0.5;
   		snowNoise += noiseValue(p*8.0)*0.125*0.25;
        dist += snowNoise*0.25;
    }
    vec2 iceberg = vec2(dist, 0.0);
    vec2 distAndMat = matmin(water, iceberg);
    return vec3(distAndMat, water.x - iceberg.x);
}

vec3 TraceOneRay(vec3 camPos, vec3 rayVec, thread vec3& normal, thread vec3& distAndMat, thread float& t) {
    normal = vec3(0.0);
    distAndMat = vec3(0.0, -1.0, 1000.0);  // Distance and material
    vec3 finalColor = vec3(0.0);
	// ----------------------------- Ray march the scene ------------------------------
	t = 0.0;
	const float maxDepth = 32.0; // farthest distance rays will travel
	vec3 pos = vec3(0.0);
    const float smallVal = 0.00625;
	// ray marching time
    for (int i = 210; i >= 0; i--)	// This is the count of the max times the ray actually marches.
    {
        // Step along the ray.
        pos = (camPos + rayVec * t);
        // This is _the_ function that defines the "distance field".
        // It's really what makes the scene geometry. The idea is that the
        // distance field returns the distance to the closest object, and then
        // we know we are safe to "march" along the ray by that much distance
        // without hitting anything. We repeat this until we get really close
        // and then break because we have effectively hit the object.
        // Port: a ray that is rising and above y = 0.007 can never be stopped
        // by the water: the waves only ever lower the surface (the noise is
        // >= 0, so the distance is y plus something non-negative), and a hit
        // needs a distance under smallVal. So only the iceberg can stop it.
        // While the iceberg is far, step by a lower bound of its distance
        // instead of the height above the water, which at grazing angles
        // takes dozens of tiny steps. The bound is the same as in
        // DistanceToObject; above y = 0.5 a rising ray can no longer reach the
        // big underwater sphere (its top is at y = 0.15, plus the 0.2 blend
        // slack), so only the small sphere is bounded there.
        float iceLB = length(pos) - 2.325;
        if (!(rayVec.y > 0.0 && pos.y > 0.5)) iceLB = min(iceLB, length(pos - vec3(-1.0, -11.85, 0.0)) - 12.4);
        if (rayVec.y > 0.0 && pos.y > 0.007 && iceLB > 0.3) {
            distAndMat = vec3(iceLB, 0.0, 1000.0);
        } else {
            distAndMat = DistanceToObject(pos);
        }

        // move down the ray a safe amount
        t += distAndMat.x;
        if (i == 0) t = maxDepth+0.01;
        // If we are very close to the object, let's call it a hit and exit this loop.
        if ((t > maxDepth) || (abs(distAndMat.x) < smallVal)) break;
    }

	// --------------------------------------------------------------------------------
	// Now that we have done our ray marching, let's put some color on this geometry.
	// If a ray actually hit the object, let's light it.
    if (t <= maxDepth)
	{
        float dist = distAndMat.x;
        // calculate the normal from the distance field. The distance field is a volume, so if you
        // sample the current point and neighboring points, you can use the difference to get
        // the normal.
        vec3 smallVec = vec3(smallVal, 0, 0);
        vec3 normalU = vec3(dist - DistanceToObject(pos - smallVec.xyy).x,
                           dist - DistanceToObject(pos - smallVec.yxy).x,
                           dist - DistanceToObject(pos - smallVec.yyx).x);
        normal = normalize(normalU);

        // Giant hack for border between water and snow to look nice.
        if (abs(distAndMat.z) < smallVal*0.25) normal = vec3(0.0, 0.2, 0.0);

        // calculate 2 ambient occlusion values. One for global stuff and one
        // for local stuff
        // Port: ambientS and ambient are only read by the water shading below,
        // so they are not computed for the iceberg.
        float ambientS = 1.0;
        float ambient = 1.0;
        if (distAndMat.y == 1.0) {
        vec3 distAndMatA = DistanceToObject(pos + normal * 0.4);
        ambientS *= saturate(distAndMatA.x*2.5);
        distAndMatA = DistanceToObject(pos + normal * 0.8);
        ambientS *= saturate(distAndMatA.x*1.25);
        ambient = ambientS;
        ambient *= saturate(DistanceToObject(pos + normal * 1.6).x*1.25*0.5);
        ambient *= saturate(DistanceToObject(pos + normal * 3.2).x*1.25*0.25);
        //ambient = max(0.05, pow(ambient, 0.5));	// tone down ambient with a pow and min clamp it.
        ambient = max(0.15, ambient);
        ambient = saturate(ambient);
        }

        // Trace a ray toward the sun for sun shadows
        float sunShadow = 1.0;
        float iter = 0.2;
		for (int i = 0; i < 10; i++)
        {
            float tempDist = DistanceToObject(pos + sunDir * iter).x;
	        sunShadow *= saturate(tempDist*10.0);
            if (tempDist <= 0.0) break;
            //iter *= 1.5;	// constant is more reliable than distance-based
            iter += max(0.1, tempDist)*1.2;
        }
        sunShadow = saturate(sunShadow);

        // Trace a ray through the solid for sub-surface scattering
        // Port: scattering is only read by the iceberg shading below, so the
        // water skips the loop.
        float scattering = 1.0;
        iter = 0.05;
        if (distAndMat.y == 0.0) {
		for (int i = 0; i < 8; i++)
        {
            float tempDist = -DistanceToObject(pos - normal * iter).x;
	        scattering *= saturate(tempDist*10.0);
            if (tempDist <= 0.0) break;
            //iter *= 1.5;	// constant is more reliable than distance-based
            iter += max(0.001, tempDist);//*0.6;
        }
        scattering = saturate(scattering);
        //scattering = (1.0-sunShadow)*(1.0-length(sunDir * iter));
        scattering = saturate(1.0-iter);
        }

        // calculate the reflection vector for highlights
        vec3 ref = reflect(rayVec, normal);

        // ------ Calculate texture color  ------
        vec3 texColor = vec3(0.0);
        // Underwater green glow
        float fade = 1.0-saturate(abs(distAndMat.z)*3.5);
        vec3 greenFade = mix(vec3(0.1, 0.995, 0.65)*0.95, vec3(0.75, 1.0, 1.0), fade*fade);
        texColor += greenFade * fade;
        texColor *= 0.75;
        // iceberg
        if (distAndMat.y == 0.0) {
            texColor = vec3(1.0);
        }
        texColor = saturate(texColor);

        // ------ Calculate lighting color ------
        // Start with sun color, standard lighting equation, and shadow
        vec3 lightColor = vec3(14.0)*sunCol * saturate(dot(sunDir, normal)) * (sunShadow*0.7+0.3);
        // weighted average the near ambient occlusion with the far for just the right look

        // apply the light to the texture.
        finalColor = texColor * lightColor;
        vec3 underwaterGlow = vec3(0.002, 0.6, 0.51);
        // water
        if (distAndMat.y == 1.0) {
	        finalColor += underwaterGlow*0.25 * length(normalU)*80.0;
	        finalColor += vec3(0.02, 0.5, 0.71)*0.35 * saturate(1.0-ambient);
            finalColor += skyCol*0.02 * ambientS;
        }
        // iceberg
        if (distAndMat.y == 0.0) {
            float fade = saturate(1.0-pos.y);
	        // Add sky color
            finalColor += (skyCol*0.6 + horizonCol*0.4)*1.5 * saturate(normal.y *0.5+0.5);
			vec3 rotPos = RotateZ(pos, sin(localTime)*sway);
            float noiseScatter = noiseValue(rotPos*32.0)*0.25 +
                noiseValue(rotPos*16.0)*0.5 +
                noiseValue(rotPos*8.0)*1.0;
	        finalColor += groundCol * 0.5 * max(-normal.y*0.5+0.5, 0.0) * (noiseScatter*0.3+0.6);
            finalColor += underwaterGlow * 0.35 * saturate(0.5-saturate(abs(pos.y*3.0)));
            finalColor += vec3(0.01, 0.55, 0.7) * saturate(scattering-sunShadow*0.3)*0.25;
            finalColor = mix((underwaterGlow + vec3(0.5, 0.9, 0.8))*0.5, finalColor, saturate(distAndMat.z*64.0)*0.75+0.25);
            finalColor *= 0.7;
        }
	}
    else
    {
        // Our ray trace hit nothing, so draw background.
        finalColor = GetEnvMap(rayVec, sunDir);
        distAndMat.y = -1.0;
    }
    return finalColor;
}

// Input is UV coordinate of pixel to render.
// Output is RGB color.
vec3 RayTrace(in vec2 fragCoord )
{
    fade = 1.0;

	vec3 camPos = vec3(0.0), camUp = vec3(0.0, 1.0, 0.0), camLookat = vec3(0.0);
	// ------------------- Set up the camera rays for ray marching --------------------
    // Map uv to [-1.0..1.0]
	vec2 uv = fragCoord.xy/iResolution.xy * 2.0 - 1.0;
    uv /= 2.0;  // zoom in

    // Do the camera fly-by animation and different scenes.
    // Time variables for start and end of each scene
    const float t0 = 0.0;
    const float t1 = 12.0;
    const float t2 = 20.0;
    const float t3 = 38.0;
    // Repeat the animation after time t3
    localTime = fract(localTime / t3) * t3;
    if (localTime < t1)
    {
        float time = localTime - t0;
        float alpha = time / (t1 - t0);
        fade = saturate(time);
        fade *= saturate(t1 - localTime);
        camPos = vec3(0.0, 0.4, -8.0);
        camPos.x -= smoothstep(0.0, 1.0, alpha) * 2.0;
        camPos.y += smoothstep(0.0, 1.0, alpha) * 2.0;
        camPos.z += smoothstep(0.0, 1.0, alpha) * 4.0;
        camUp=vec3(0,1,0);
        camLookat=vec3(0,-0.5,0.5);
        camLookat.y -= smoothstep(0.0, 1.0, alpha) * 0.5;
    } else if (localTime < t2)
    {
        float time = localTime - t1;
        float alpha = time / (t2 - t1);
        fade = saturate(time);
        fade *= saturate(t2 - localTime);
        camPos = vec3(2.0, 4.3, -0.5);
        camPos.y -= alpha * 3.5;
        camPos.x = sin(alpha*1.0) * 9.2;
        camPos.z = cos(alpha*1.0) * 6.2;
        camUp=normalize(vec3(0,1,-0.005 + alpha * 0.005));
        camLookat=vec3(0,-1.5,0.0);
        camLookat.y += smoothstep(0.0, 1.0, alpha) * 1.5;
    } else if (localTime < t3)
    {
        float time = localTime - t2;
        float alpha = time / (t3 - t2);
        fade = saturate(time);
        fade *= saturate(t3 - localTime);
        camPos = vec3(-9.0, 1.3, -10.0);
        //camPos.y -= alpha * 8.0;
        camPos.x += alpha * 14.0;
        camPos.z += alpha * 7.0;
        camUp=normalize(vec3(0,1,0.0));
        camLookat=vec3(0.0,0.0,0.0);
    }

	// Camera setup for ray tracing / marching
	vec3 camVec=normalize(camLookat - camPos);
	vec3 sideNorm=normalize(cross(camUp, camVec));
	vec3 upNorm=cross(camVec, sideNorm);
	vec3 worldFacing=(camPos + camVec);
	vec3 worldPix = worldFacing + uv.x * sideNorm * (iResolution.x/iResolution.y) + uv.y * upNorm;
	vec3 rayVec = normalize(worldPix - camPos);

	vec3 finalColor = vec3(0.0);

    vec3 normal = vec3(0.0);
    vec3 distAndMat = vec3(0.0);
    float t = 0.0;
    // Port: the primary ray and the water reflection ray run through one
    // call of TraceOneRay in a two-pass loop instead of two separate calls.
    // Same maths, but the compiler emits the big function once, not twice.
    vec3 rayOrigin = camPos;
    vec3 rayDir = rayVec;
    float rayWeight = 1.0;
    for (int pass = 0; pass < 2; pass++) {
        vec3 passColor = TraceOneRay(rayOrigin, rayDir, normal, distAndMat, t);
        finalColor += passColor * rayWeight;
        if (pass == 0 && distAndMat.y == 1.0) {
            vec3 ref = normalize(reflect(rayVec, normal));
            ref.y = abs(ref.y);
            vec3 newStartPos = (camPos + rayVec * t) + normal * 0.02; // nudge away.
            float fresnel = saturate(1.0 - dot(-rayVec, normal));
            fresnel = fresnel * fresnel * fresnel * fresnel * fresnel * fresnel;
            fresnel = mix(0.05, 0.9, fresnel);
            rayOrigin = newStartPos;
            rayDir = ref;
            rayWeight = fresnel;
        } else {
            break;
        }
    }

    // vignette?
    finalColor *= vec3(1.0) * saturate(1.0 - length(uv/2.5));
    finalColor *= exposure;

	// output the final color without gamma correction - will do gamma later.
	return vec3(clamp(finalColor, 0.0, 1.0)*saturate(fade));
}

void mainImage(thread vec4& fragColor, in vec2 fragCoord)
{
    // Regular real-time rendering
    localTime = iTime * timeScale;
    vec3 finalColor = RayTrace(fragCoord);

    fragColor = vec4(sqrt(clamp(finalColor, 0.0, 1.0)),1.0);
}
