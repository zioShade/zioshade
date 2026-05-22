// Tests: deeply nested struct access passed to function
precision mediump float;
uniform vec2 u_resolution;

struct Inner { float x; float y; };
struct Middle { Inner a; Inner b; float scale; };
struct Outer { Middle m; vec3 tint; };

float compute(Outer o, vec2 uv) {
    float dx = o.m.a.x - uv.x;
    float dy = o.m.b.y - uv.y;
    return o.m.scale / (dx * dx + dy * dy + 0.01) * o.tint.r;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Outer o;
    o.m.a.x = 0.5;
    o.m.a.y = 0.3;
    o.m.b.x = 0.7;
    o.m.b.y = 0.5;
    o.m.scale = 1.5;
    o.tint = vec3(0.8, 0.6, 0.4);
    
    float v = compute(o, uv);
    gl_FragColor = vec4(vec3(fract(v)), 1.0);
}
