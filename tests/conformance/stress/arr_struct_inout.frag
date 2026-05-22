// Tests: array of structs with function modifying elements
precision mediump float;
uniform vec2 u_resolution;

struct Point {
    float x;
    float y;
};

void offsetPoint(inout Point p, float dx, float dy) {
    p.x += dx;
    p.y += dy;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Point pts[4];
    pts[0] = Point(0.2, 0.3);
    pts[1] = Point(0.7, 0.2);
    pts[2] = Point(0.8, 0.8);
    pts[3] = Point(0.3, 0.7);
    
    // Modify via function with inout
    for (int i = 0; i < 4; i++) {
        offsetPoint(pts[i], uv.x * 0.1, uv.y * 0.1);
    }
    
    // Find closest point
    float minDist = 999.0;
    for (int i = 0; i < 4; i++) {
        float d = length(uv - vec2(pts[i].x, pts[i].y));
        if (d < minDist) minDist = d;
    }
    
    gl_FragColor = vec4(vec3(1.0 - minDist * 2.0), 1.0);
}
