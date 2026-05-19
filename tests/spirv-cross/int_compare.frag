#version 450

// Test: integer comparison chains
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    int x = int(uv.x * 10.0);
    int y = int(uv.y * 10.0);

    bool a = x < y;
    bool b = x > y;
    bool c = x == y;
    bool d = x != y;
    bool e = x <= 5 && y >= 3;

    float r = float(a) * 0.5 + float(c) * 0.5;
    float g = float(b) * 0.5 + float(d) * 0.5;
    float bl = float(e);

    gl_FragColor = vec4(r, g, bl, 1.0);
}
