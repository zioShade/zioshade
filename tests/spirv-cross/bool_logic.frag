#version 450

// Test: boolean logic chains with short-circuit patterns
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float y = uv.y;

    bool a = x > 0.3 && y > 0.3;
    bool b = x > 0.6 || y > 0.6;
    bool c = !(x > 0.5);
    bool d = (x > 0.2 && x < 0.8) && (y > 0.2 && y < 0.8);

    float r = a ? 1.0 : 0.0;
    float g = b ? 1.0 : 0.0;
    float bl = c ? 0.8 : 0.2;
    float al = d ? 1.0 : 0.5;

    gl_FragColor = vec4(r, g, bl, al);
}
