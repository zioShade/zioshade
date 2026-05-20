#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Spiral galaxy with arms
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Two spiral arms
    float arm1 = exp(-pow((r - 0.1 - a * 0.12) * 4.0, 2.0));
    float arm2 = exp(-pow((r - 0.1 - (a + 3.14159) * 0.12) * 4.0, 2.0));
    float arms = max(arm1, arm2) * step(0.05, r) * step(r, 0.9);
    // Core glow
    float core = exp(-r * r * 20.0);
    // Stars
    float star = fract(sin(dot(floor(uv * 300.0), vec2(127.1, 311.7))) * 43758.5);
    vec3 col = vec3(0.01, 0.01, 0.03);
    col += vec3(0.6, 0.5, 0.9) * arms * 0.8;
    col += vec3(0.4, 0.6, 0.9) * arms * 0.3;
    col += vec3(1.0, 0.95, 0.8) * core;
    col += vec3(0.8) * step(0.99, star) * 0.3;
    fragColor = vec4(col, 1.0);
}
