// Tests: deeply nested if-else with 6+ levels modifying different variable types
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float f = 0.0;
    vec2 v = vec2(0.0);
    int level = 0;
    
    if (uv.x > 0.1) {
        f += 0.1;
        level = 1;
        if (uv.x > 0.2) {
            f += 0.1;
            v.x += 0.2;
            level = 2;
            if (uv.x > 0.4) {
                f += 0.2;
                v.y += 0.3;
                level = 3;
                if (uv.x > 0.6) {
                    f += 0.2;
                    v += 0.1;
                    level = 4;
                    if (uv.x > 0.8) {
                        f += 0.2;
                        v.x += 0.1;
                        level = 5;
                    }
                }
            }
        }
    } else {
        f = 0.05;
        v = uv;
        level = 0;
    }
    
    float r = f + v.x;
    float g = f + v.y;
    float b = float(level) / 5.0;
    
    gl_FragColor = vec4(clamp(vec3(r, g, b), 0.0, 1.0), 1.0);
}
