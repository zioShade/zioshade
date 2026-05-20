#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Concrete texture with cracks
    float n1 = fract(sin(dot(floor(uv * 5.0), vec2(127.1, 311.7))) * 43758.5);
    float n2 = fract(sin(dot(floor(uv * 13.0), vec2(269.5, 183.3))) * 43758.5);
    vec3 concrete = vec3(0.6, 0.6, 0.58) * (0.85 + n1 * 0.15);
    // Cracks
    float crack1 = smoothstep(0.008, 0.003, abs(uv.y - 3.0 - sin(uv.x * 0.8) * 0.5));
    float crack2 = smoothstep(0.008, 0.003, abs(uv.x - 5.0 - sin(uv.y * 1.2) * 0.3));
    vec3 crack_col = vec3(0.3, 0.3, 0.28);
    vec3 col = concrete;
    col = mix(col, crack_col, max(crack1, crack2));
    // Aggregate dots
    col += vec3(0.05) * smoothstep(0.1, 0.08, n2);
    fragColor = vec4(col, 1.0);
}
