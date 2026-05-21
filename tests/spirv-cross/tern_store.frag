#version 310 es
precision highp float;
out vec4 fragColor;

// Test: ternary result stored and reused
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    vec3 a = r < 0.3 ? vec3(0.8, 0.2, 0.1) : vec3(0.1, 0.3, 0.8);
    vec3 b = uv.y > 0.0 ? a * 1.5 : a * 0.5;
    vec3 c = b.r > 0.5 ? b + vec3(0.1) : b - vec3(0.05);
    fragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
}
