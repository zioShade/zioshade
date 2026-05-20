#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Spirograph with multiple parameters
    float R = 0.5;
    float r_inner = 0.2;
    float d = 0.15;
    float min_d = 1.0;
    for (int i = 0; i <= 100; i++) {
        float t = float(i) / 100.0 * 6.28 * 3.0;
        float x = (R - r_inner) * cos(t) + d * cos((R - r_inner) / r_inner * t);
        float y = (R - r_inner) * sin(t) - d * sin((R - r_inner) / r_inner * t);
        float dist = length(uv - vec2(x, y));
        min_d = min(min_d, dist);
    }
    float curve = smoothstep(0.01, 0.005, min_d);
    vec3 col = vec3(0.02) + vec3(0.3, 0.7, 0.9) * curve;
    fragColor = vec4(col, 1.0);
}
