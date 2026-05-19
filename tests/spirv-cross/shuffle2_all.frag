#version 450

// Test: vector shuffle patterns (all 2-component combinations)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec4 a = vec4(0.1, 0.2, 0.3, 0.4);

    vec2 b = a.xx;
    vec2 c = a.yy;
    vec2 d = a.zz;
    vec2 e = a.ww;
    vec2 f = a.xy;
    vec2 g = a.yx;
    vec2 h = a.xz;
    vec2 i = a.zw;

    float r = b.x + f.x;
    float g2 = c.x + g.y;
    float bl = d.x + h.y;

    gl_FragColor = vec4(r + uv.x * 0.3, g2 + uv.y * 0.3, bl, 1.0);
}
