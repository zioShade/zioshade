#version 450

// Test: float comparison patterns (ord vs unord)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float y = uv.y;

    bool a = x == y;
    bool b = x != y;
    bool c = x < y;
    bool d = x > y;
    bool e = x <= y;
    bool f = x >= y;

    float r = float(a || b);
    float g = float(c || d);
    float bl = float(e || f);

    gl_FragColor = vec4(r, g, bl, 1.0);
}
