#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec4 a = vec4(1.0, 2.0, 3.0, 4.0);
    vec4 b = vec4(5.0, 6.0, 7.0, 8.0);
    // Chain of shuffles
    vec2 v1 = a.xy;
    vec2 v2 = a.zw;
    vec2 v3 = b.yw;
    vec4 c = vec4(v1, v2);
    vec4 d = vec4(v3, v1);
    vec4 e = c + d;
    vec2 f = e.xz;
    vec4 g = vec4(f.yx, v3);
    fragColor = g * 0.1;
}
