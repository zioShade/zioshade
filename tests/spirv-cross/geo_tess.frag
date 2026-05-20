#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Geometric tessellation pattern
    float scale = 6.0;
    vec2 p = uv * scale;
    vec2 id = floor(p);
    vec2 f = fract(p);
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    // Triangle subdivision
    float d1 = f.x + f.y;
    float d2 = (1.0 - f.x) + f.y;
    float tri = h > 0.5 ? d1 : d2;
    float edge = smoothstep(0.05, 0.02, abs(tri - 0.5));
    // Fill color based on which side of triangle
    float fill = step(0.5, tri);
    vec3 col_a = vec3(0.2, 0.4, 0.6);
    vec3 col_b = vec3(0.6, 0.3, 0.4);
    vec3 col = mix(col_a, col_b, fill);
    col = mix(col, vec3(0.9), edge * 0.5);
    fragColor = vec4(col, 1.0);
}
