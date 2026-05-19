#version 450

// Test: complex condition with multiple && and ||
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float y = uv.y;

    bool a = x > 0.2 && x < 0.8;
    bool b = y > 0.3 && y < 0.7;
    bool c = (x > 0.4 && y > 0.4) || (x < 0.1 && y < 0.1);
    bool d = !a && !b;
    bool e = (a || b) && !c;

    float r = float(a);
    float g = float(c);
    float b2 = float(e);

    gl_FragColor = vec4(r, g, b2, 1.0);
}
