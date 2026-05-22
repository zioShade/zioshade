// Tests: deeply nested if/else with multiple struct variables
precision mediump float;
uniform vec2 u_resolution;

struct Ray {
    vec3 origin;
    vec3 dir;
};

struct Hit {
    float t;
    int id;
};

Hit trace(Ray r) {
    Hit h;
    h.t = length(r.dir);
    h.id = int(r.origin.x * 10.0);
    return h;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Ray r;
    r.origin = vec3(uv, 0.0);
    r.dir = vec3(0.0, 0.0, 1.0);
    
    Hit h = trace(r);
    
    float brightness;
    if (h.id > 5) {
        if (h.t > 0.5) {
            brightness = 0.9;
        } else {
            brightness = 0.7;
        }
    } else {
        if (h.id > 2) {
            brightness = 0.5;
        } else {
            brightness = 0.3;
        }
    }
    
    vec3 col = vec3(brightness) * vec3(float(h.id) * 0.1, uv.y, 1.0 - uv.x);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
