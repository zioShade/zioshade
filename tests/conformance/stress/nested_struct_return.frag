// Tests: nested struct return from function (no chaining, no conditional)
precision mediump float;
uniform vec2 u_resolution;

struct Inner {
    float a;
    float b;
};

struct Outer {
    Inner inner;
    float c;
};

Outer makeOuter(float x, float y) {
    Outer o;
    o.inner.a = x;
    o.inner.b = y;
    o.c = x + y;
    return o;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    Outer o = makeOuter(uv.x, uv.y);
    
    float r = o.inner.a;
    float g = o.inner.b;
    float b = o.c;
    
    gl_FragColor = vec4(r, g, b * 0.5, 1.0);
}
