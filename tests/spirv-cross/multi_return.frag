#version 310 es
precision highp float;
out vec4 fragColor;

// Test: function with multiple return paths
vec3 getGradient(float t) {
    if (t < 0.25) return vec3(0.1, 0.1, 0.5);
    if (t < 0.5) return vec3(0.1, 0.5, 0.5);
    if (t < 0.75) return vec3(0.5, 0.5, 0.1);
    return vec3(0.8, 0.2, 0.1);
}

void main() {
    vec2 uv = gl_FragCoord.xy * 0.1;
    float t = uv.x / 10.0;
    vec3 col = getGradient(t);
    col *= 0.8 + 0.2 * sin(uv.y * 0.5);
    fragColor = vec4(col, 1.0);
}
