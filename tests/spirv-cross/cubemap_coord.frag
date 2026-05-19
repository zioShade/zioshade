#version 450

// Test: cubemap-like coordinate mapping
vec3 cubeMap(vec2 uv) {
    vec3 dir = vec3(0.0);
    float x = uv.x * 2.0 - 1.0;
    float y = uv.y * 2.0 - 1.0;

    // Simple 6-face selection
    int face = 0;
    if (abs(x) > abs(y)) {
        face = x > 0.0 ? 0 : 1;
        dir = x > 0.0 ? vec3(1.0, y, 0.0) : vec3(-1.0, y, 0.0);
    } else {
        face = y > 0.0 ? 2 : 3;
        dir = y > 0.0 ? vec3(x, 1.0, 0.0) : vec3(x, -1.0, 0.0);
    }

    return normalize(dir);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 dir = cubeMap(uv);
    vec3 col = dir * 0.5 + 0.5;
    gl_FragColor = vec4(col, 1.0);
}
