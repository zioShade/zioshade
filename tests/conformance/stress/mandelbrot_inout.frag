// Tests: modifying loop variable via function inout param
precision mediump float;
uniform vec2 u_resolution;

void step(inout float x, inout float y, float cx, float cy) {
    float nx = x * x - y * y + cx;
    float ny = 2.0 * x * y + cy;
    x = nx;
    y = ny;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float cx = uv.x * 2.0 - 1.5;
    float cy = uv.y * 2.0 - 1.0;
    float x = 0.0;
    float y = 0.0;
    int iter = 0;
    
    for (int i = 0; i < 30; i++) {
        step(x, y, cx, cy);
        iter = i;
        if (x * x + y * y > 4.0) break;
    }
    
    float t = float(iter) / 30.0;
    vec3 col = vec3(t, t * t, sqrt(t));
    
    gl_FragColor = vec4(col, 1.0);
}
