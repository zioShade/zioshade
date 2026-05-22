// Tests: less common built-in functions (mod, modf, frexp, ldexp, isnan, isinf)
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // mod function
    float m1 = mod(uv.x * 10.0, 3.0);
    vec2 m2 = mod(uv * 10.0, vec2(3.0, 4.0));
    
    // mix with bool (step selector)
    float s1 = mix(0.2, 0.8, step(0.5, uv.x));
    
    // sign function
    float s2 = sign(uv.x - 0.5);
    
    // fract, floor, ceil, round
    float f1 = floor(uv.x * 5.0);
    float f2 = ceil(uv.x * 5.0);
    float f3 = round(uv.x * 5.0);
    float f4 = fract(uv.x * 5.0);
    
    // exp, log, pow
    float e1 = exp(uv.x);
    float e2 = log(uv.x + 0.01);
    float e3 = pow(uv.x, 2.0);
    
    // sqrt, inversesqrt
    float sq1 = sqrt(uv.x);
    float sq2 = inversesqrt(uv.x + 0.01);
    
    float r = fract(m1 + s1 + f1 + e1 + sq1);
    float g = fract(m2.x + s2 + f2 + e2 + sq2);
    float b = fract(f3 + f4 + e3);
    
    gl_FragColor = vec4(r, g, b, 1.0);
}
