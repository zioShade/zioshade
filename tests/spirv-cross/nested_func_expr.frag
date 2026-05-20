#version 310 es
precision highp float;
out vec4 fragColor;

float noise(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float fbm(vec2 p) {
    float f = 0.0;
    float w = 0.5;
    for (int i = 0; i < 5; i++) {
        f += w * noise(p);
        p *= 2.0;
        w *= 0.5;
    }
    return f;
}

void main() {
    vec2 uv = gl_FragCoord.xy;
    // Nested function expressions
    float v = fbm(fbm(uv * 0.01) * 10.0 + uv * 0.02);
    float w = noise(vec2(fbm(uv * 0.03), fbm(uv * 0.04)));
    vec3 col = mix(vec3(0.2, 0.3, 0.5), vec3(0.8, 0.7, 0.4), v);
    col = mix(col, vec3(0.1, 0.2, 0.3), w);
    fragColor = vec4(col, 1.0);
}
