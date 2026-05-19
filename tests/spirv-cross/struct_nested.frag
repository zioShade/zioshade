#version 450
layout(location = 0) out vec4 FragColor;
struct Inner { float a; float b; };
struct Outer { Inner inner; float scale; };
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    Outer o;
    o.inner.a = uv.x;
    o.inner.b = uv.y;
    o.scale = 2.0;
    float val = (o.inner.a + o.inner.b) * o.scale;
    FragColor = vec4(val * 0.25, o.inner.a, o.inner.b, 1.0);
}
