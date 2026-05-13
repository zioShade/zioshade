
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    int quadrant = int(step(0.5, uv.x)) + 2 * int(step(0.5, uv.y));
    vec3 col;
    switch (quadrant) {
        case 0: col = vec3(1.0, 0.0, 0.0); break;
        case 1: col = vec3(0.0, 1.0, 0.0); break;
        case 2: col = vec3(0.0, 0.0, 1.0); break;
        case 3: col = vec3(1.0, 1.0, 0.0); break;
        default: col = vec3(0.0); break;
    }
    FragColor = vec4(col, 1.0);
}
