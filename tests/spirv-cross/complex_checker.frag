#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Complex checkerboard with compound accumulate
    float scale = 8.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    
    float pattern = 0.0;
    pattern += step(0.5, fract(f.x * 2.0));
    pattern += step(0.5, fract(f.y * 2.0));
    pattern += step(0.5, fract(f.x * 3.0 + f.y * 3.0));
    pattern = mod(pattern, 2.0);
    
    vec3 col_a = vec3(0.15, 0.3, 0.5);
    vec3 col_b = vec3(0.6, 0.4, 0.2);
    vec3 col = mix(col_a, col_b, pattern);
    col *= smoothstep(1.2, 0.5, length(uv));
    fragColor = vec4(col, 1.0);
}
