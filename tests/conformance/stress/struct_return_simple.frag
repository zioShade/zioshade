// Tests: struct with function return, no chaining
precision mediump float;
uniform vec2 u_resolution;

struct Point {
    float x;
    float y;
};

Point makePoint(float a, float b) {
    Point p;
    p.x = a;
    p.y = b;
    return p;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Point p1 = makePoint(uv.x, uv.y);
    Point p2 = makePoint(1.0 - uv.x, 1.0 - uv.y);
    
    float d = sqrt((p1.x - p2.x) * (p1.x - p2.x) + (p1.y - p2.y) * (p1.y - p2.y));
    
    vec3 col = vec3(d, p1.x * p2.y, p2.x * p1.y);
    gl_FragColor = vec4(col, 1.0);
}
