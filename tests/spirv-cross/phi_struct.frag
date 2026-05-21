#version 310 es
precision highp float;
out vec4 fragColor;

struct Params { float a; float b; };

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    Params p;
    float extra;
    if (r < 0.5) {
        p.a = 0.8; p.b = 0.3; extra = 1.0;
    } else {
        p.a = 0.2; p.b = 0.7; extra = 0.5;
    }
    vec3 col = vec3(p.a * extra, p.b, p.a + p.b);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
