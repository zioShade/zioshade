#version 430
layout(location = 0) out vec4 FragColor;

// Test: switch statement rendering
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    int sector = int(uv.x * 4.0);
    vec3 col;
    switch (sector) {
        case 0: col = vec3(1.0, 0.0, 0.0); break;
        case 1: col = vec3(0.0, 1.0, 0.0); break;
        case 2: col = vec3(0.0, 0.0, 1.0); break;
        default: col = vec3(1.0, 1.0, 0.0); break;
    }
    col *= smoothstep(0.3, 0.7, uv.y);
    FragColor = vec4(col, 1.0);
}
