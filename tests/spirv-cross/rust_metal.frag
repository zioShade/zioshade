#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Rusted metal texture
    float n = fract(sin(dot(floor(uv * 3.0), vec2(127.1, 311.7))) * 43758.5);
    float n2 = fract(sin(dot(floor(uv * 7.0), vec2(269.5, 183.3))) * 43758.5);
    // Base metal
    vec3 metal = vec3(0.4, 0.38, 0.35);
    // Rust spots
    float rust = smoothstep(0.4, 0.6, n) * smoothstep(0.3, 0.5, n2);
    vec3 rust_col = vec3(0.6, 0.3, 0.1);
    vec3 col = mix(metal, rust_col, rust);
    // Scratches
    float scratch = smoothstep(0.01, 0.005, abs(sin(uv.x * 50.0 + n * 5.0)));
    col = mix(col, metal * 0.8, scratch * 0.3);
    fragColor = vec4(col, 1.0);
}
