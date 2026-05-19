#version 450

// Test: smooth minimum (polynomial smooth min)
float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float d1 = length(uv - vec2(0.3, 0.5));
    float d2 = length(uv - vec2(0.7, 0.5));
    float d = smin(d1, d2, 0.1);

    vec3 col = d < 0.3 ? vec3(0.8, 0.4, 0.2) : vec3(0.1, 0.2, 0.3);
    gl_FragColor = vec4(col, 1.0);
}
