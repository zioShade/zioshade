#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test switch with multiple cases and default
    int a = int(uv.x * 4.0);
    float r;
    switch (a) {
        case 0: r = 0.0; break;
        case 1: r = 0.33; break;
        case 2: r = 0.66; break;
        default: r = 1.0; break;
    }

    // Test matrix element access chain: m[col][row]
    mat4 m = mat4(1.0);
    m[1][1] = 2.0;
    m[2][2] = 3.0;
    float d = m[0][0] + m[1][1] + m[2][2];

    fragColor = vec4(r, d / 6.0, uv.y, 1.0);
}
