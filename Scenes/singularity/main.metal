/*
    "Singularity" by @XorDev

    https://www.shadertoy.com/view/3csSWB

    A whirling blackhole.
    Feel free to code golf!

    FabriceNeyret2: -19
    dean_the_coder: -12
    iq: -4
*/

/*
    Licence: MIT License, Copyright (c) 2025 Xor. Stated in the LICENSE file and
    README of https://github.com/XorDev/Singularity, the repository this shader
    is published in.

    Ported to Metal Shading Language for MacOS Live Wallpaper. Changes from the
    original:
      - The golfed one-liner declarations are written out as separate
        statements, in the same order, with the same values. The parts of the
        golf that GLSL does implicitly are spelled out:
          * mat2(1, 1, vec2) is written mat2(vec2(1, 1), vec2);
          * mat2(vec4) is written mat2(v.xy, v.zw);
          * a=dot(c,c) inside the cos() argument is a statement of its own;
          * w is declared without a value and relied on being zero; it is
            initialised to zero here;
          * "for (; i++<9.; ...)" is kept as a post-increment test, so the body
            runs with i = 1.2, 2.2 ... 9.2 exactly as in the original.
      - The output parameter is declared thread vec4& instead of out vec4.
      - Time runs at TIME_SCALE (0.5) of the original speed, to suit a desktop
        background. Set it to 1.0 for the original pace.
      - The maths, constants and colouring are untouched.
*/

#define TIME_SCALE 0.5

void mainImage(thread vec4& O, vec2 F)
{
    float t = iTime * TIME_SCALE;

    //Iterator and attenuation (distance-squared)
    float i = .2, a = 0.;

    //Resolution for scaling and centering
    vec2 r = iResolution.xy;
    //Centered ratio-corrected coordinates
    vec2 p = ( F+F - r ) / r.y / .7;
    //Diagonal vector for skewing
    vec2 d = vec2(-1, 1);
    //Blackhole center
    vec2 b = p - i*d;
    //Rotate and apply perspective
    vec2 c = p * mat2(vec2(1, 1), d/(.1 + i/dot(b,b)));
    //Rotate into spiraling coordinates
    a = dot(c,c);
    vec4 rot = cos(.5*log(a) + t*i + vec4(0,33,11,0));
    vec2 v = c * mat2(rot.xy, rot.zw) / i;
    //Waves cumulative total for coloring
    vec2 w = vec2(0.);

    //Loop through waves
    for (; i++ < 9.; w += 1. + sin(v))
        //Distort coordinates
        v += .7 * sin(v.yx*i + t) / i + .5;

    //Acretion disk radius
    i = length( sin(v/.3)*.4 + c*(3.+d) );

    //Red/blue gradient
    O = 1. - exp( -exp( c.x * vec4(.6,-.4,-1,0) )
               //Wave coloring
               /  w.xyyx
               //Acretion disk brightness
               / ( 2. + i*i/4. - i )
               //Center darkness
               / ( .5 + 1. / a )
               //Rim highlight
               / ( .03 + abs( length(p)-.7 ) )
         );
}
