// Tests: early return from function with multiple return paths and local array
precision mediump float;
uniform vec2 u_resolution;

float lookup(float x) {
    float table[5];
    table[0] = 0.1;
    table[1] = 0.3;
    table[2] = 0.5;
    table[3] = 0.7;
    table[4] = 0.9;
    
    for (int i = 0; i < 5; i++) {
        if (x < table[i]) {
            return table[i];
        }
    }
    return 1.0;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float a = lookup(uv.x);
    float b = lookup(uv.y);
    
    vec3 col = vec3(a, b, (a + b) * 0.5);
    gl_FragColor = vec4(col, 1.0);
}
