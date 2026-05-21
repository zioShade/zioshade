#version 310 es
precision highp float;
out vec4 fragColor;

struct Inner2 { vec3 rgb; float alpha; };
struct Outer2 { Inner2 fg; Inner2 bg; };

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    Outer2 o = Outer2(Inner2(vec3(0.8, 0.2, 0.1), 1.0), Inner2(vec3(0.1, 0.2, 0.8), 0.5));
    float blend = sin(uv.x * 10.0) * 0.5 + 0.5;
    vec3 col = mix(o.bg.rgb, o.fg.rgb, blend * o.fg.alpha);
    if (length(uv) < 0.5) {
        col *= o.bg.alpha;
    }
    fragColor = vec4(col, 1.0);
}
