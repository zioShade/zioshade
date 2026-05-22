// Tests: struct variable stored in loop body, loaded after loop
// Pattern: loop-carried struct dependency
precision mediump float;
uniform vec2 u_resolution;

struct Color {
    float r;
    float g;
    float b;
};

Color mixColor(Color a, Color b, float t) {
    Color c;
    c.r = a.r * (1.0 - t) + b.r * t;
    c.g = a.g * (1.0 - t) + b.g * t;
    c.b = a.b * (1.0 - t) + b.b * t;
    return c;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Color base;
    base.r = 0.1;
    base.g = 0.2;
    base.b = 0.3;
    
    Color target;
    target.r = uv.x;
    target.g = uv.y;
    target.b = 0.5;
    
    Color cur = base;
    for (int i = 0; i < 5; i++) {
        float t = float(i) / 5.0;
        cur = mixColor(cur, target, t * 0.1);
    }
    
    gl_FragColor = vec4(cur.r, cur.g, cur.b, 1.0);
}
