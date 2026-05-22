// Tests: nested function calls returning different types
precision mediump float;
uniform vec2 u_resolution;

vec2 rotate2d(vec2 v, float a) {
    float c = cos(a);
    float s = sin(a);
    return vec2(v.x * c - v.y * s, v.x * s + v.y * c);
}

float pattern(vec2 p) {
    vec2 q = rotate2d(p, 0.5);
    return sin(q.x * 10.0) * cos(q.y * 10.0);
}

float fbm(vec2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        val += amp * pattern(p);
        p = rotate2d(p, 1.57);
        amp *= 0.5;
    }
    return val;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float n = fbm(uv * 3.0);
    
    vec3 col = vec3(n * 0.5 + 0.5, n * n, abs(n));
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
