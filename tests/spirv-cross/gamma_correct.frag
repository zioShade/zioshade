#version 450

// Test: gamma correction and color space conversion
vec3 linearToSrgb(vec3 c) {
    return pow(c, vec3(1.0 / 2.2));
}

vec3 srgbToLinear(vec3 c) {
    return pow(c, vec3(2.2));
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 linear = vec3(uv, 0.5);
    vec3 srgb = linearToSrgb(linear);
    vec3 back = srgbToLinear(srgb);
    // Should be approximately the same as original
    gl_FragColor = vec4(back, 1.0);
}
