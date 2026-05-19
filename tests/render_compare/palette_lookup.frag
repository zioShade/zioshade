#version 430
layout(location = 0) out vec4 FragColor;

// Test: vec3 array palette lookup (exercises copyMemoryOpt fix)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 palette[4];
    palette[0] = vec3(1.0, 0.2, 0.1);
    palette[1] = vec3(0.1, 1.0, 0.3);
    palette[2] = vec3(0.2, 0.3, 1.0);
    palette[3] = vec3(1.0, 1.0, 0.2);
    int idx = int(uv.x * 3.999);
    idx = clamp(idx, 0, 3);
    vec3 col = vec3(0.0);
    for (int i = 0; i < 4; i++) {
        if (i == idx) col = palette[i];
    }
    col *= smoothstep(0.3, 0.7, uv.y);
    FragColor = vec4(col, 1.0);
}
