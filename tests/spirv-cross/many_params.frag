#version 310 es
precision highp float;
out vec4 fragColor;

// Test: function with many parameters
vec3 blend(float r, float g, float b, float a, vec3 bg, vec3 fg) {
    return mix(bg, fg, vec3(a)) * vec3(r, g, b);
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float t = sin(length(uv) * 5.0) * 0.5 + 0.5;
    vec3 col = blend(1.0, 0.8, 0.6, t, vec3(0.1, 0.2, 0.4), vec3(0.9, 0.5, 0.2));
    fragColor = vec4(col, 1.0);
}
