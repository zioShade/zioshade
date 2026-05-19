#version 450
layout(location = 0) out vec4 FragColor;
struct Grid {
    float cells[9];
    vec2 offset;
};
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    Grid g;
    g.offset = uv;
    for (int i = 0; i < 9; i++) {
        g.cells[i] = float(i) / 9.0;
    }
    FragColor = vec4(g.cells[0], uv.y, 0.5, 1.0);
}
