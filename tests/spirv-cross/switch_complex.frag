#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    int mode = int(uv.x * 4.999);
    vec3 col;
    switch (mode) {
        case 0: col = vec3(1.0, 0.0, 0.0); break;
        case 1: col = vec3(0.0, 1.0, 0.0); break;
        case 2: col = vec3(0.0, 0.0, 1.0); break;
        case 3: col = vec3(1.0, 1.0, 0.0); break;
        case 4: col = vec3(0.0, 1.0, 1.0); break;
        default: col = vec3(1.0, 0.0, 1.0); break;
    }
    col *= smoothstep(0.2, 0.8, uv.y);
    FragColor = vec4(col, 1.0);
}
