#version 450

// Test: multiple early returns with default
vec3 getColor(float t) {
    if (t < 0.2) return vec3(1.0, 0.0, 0.0);
    if (t < 0.4) return vec3(1.0, 0.5, 0.0);
    if (t < 0.6) return vec3(1.0, 1.0, 0.0);
    if (t < 0.8) return vec3(0.0, 1.0, 0.0);
    return vec3(0.0, 0.0, 1.0);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = getColor(uv.x) * smoothstep(0.0, 1.0, uv.y);
    gl_FragColor = vec4(col, 1.0);
}
