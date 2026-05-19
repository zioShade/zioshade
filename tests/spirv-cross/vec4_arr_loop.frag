#version 450
layout(location = 0) out vec4 FragColor;

// Test: complex array pattern with vec4
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec4 colors[3];
    colors[0] = vec4(1.0, 0.3, 0.1, 1.0);
    colors[1] = vec4(0.1, 0.8, 0.3, 1.0);
    colors[2] = vec4(0.2, 0.3, 0.9, 1.0);
    int idx = int(uv.x * 2.999);
    idx = clamp(idx, 0, 2);
    vec4 col = vec4(0.0);
    for (int i = 0; i < 3; i++) {
        if (i == idx) col = colors[i];
    }
    col.rgb *= smoothstep(0.3, 0.7, uv.y);
    FragColor = col;
}
