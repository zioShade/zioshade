#version 450

// Test: smoothstep and step in various configurations
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float a = smoothstep(0.0, 1.0, uv.x);
    float b = step(0.5, uv.y);
    float c = smoothstep(0.2, 0.8, uv.x + uv.y);
    vec2 d = smoothstep(vec2(0.2, 0.3), vec2(0.7, 0.8), uv);
    vec2 e = step(vec2(0.4, 0.6), uv);

    gl_FragColor = vec4(a * b + c, d.x * e.y, d.y, 1.0);
}
