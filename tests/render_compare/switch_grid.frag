#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    int ix = int(uv.x * 4.0);
    int iy = int(uv.y * 4.0);
    int idx = ix + iy * 4;
    vec3 col;
    switch (idx) {
        case 0: col = vec3(0.9, 0.1, 0.1); break;
        case 1: col = vec3(0.1, 0.9, 0.1); break;
        case 2: col = vec3(0.1, 0.1, 0.9); break;
        case 3: col = vec3(0.9, 0.9, 0.1); break;
        case 4: col = vec3(0.9, 0.1, 0.9); break;
        case 5: col = vec3(0.1, 0.9, 0.9); break;
        case 6: col = vec3(0.5, 0.5, 0.1); break;
        case 7: col = vec3(0.1, 0.5, 0.5); break;
        case 8: col = vec3(0.5, 0.1, 0.5); break;
        case 9: col = vec3(0.3, 0.7, 0.3); break;
        case 10: col = vec3(0.7, 0.3, 0.3); break;
        case 11: col = vec3(0.3, 0.3, 0.7); break;
        case 12: col = vec3(0.8, 0.6, 0.2); break;
        case 13: col = vec3(0.2, 0.8, 0.6); break;
        case 14: col = vec3(0.6, 0.2, 0.8); break;
        case 15: col = vec3(0.4, 0.4, 0.4); break;
        default: col = vec3(0.0); break;
    }
    FragColor = vec4(col, 1.0);
}
