// Tests: local array declaration with initializer-like pattern
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Declare and initialize local arrays
    float weights[4];
    weights[0] = 0.1;
    weights[1] = 0.2;
    weights[2] = 0.3;
    weights[3] = 0.4;
    
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        sum += weights[i];
    }
    
    // Array of vec3
    vec3 colors[3];
    colors[0] = vec3(1.0, 0.0, 0.0);
    colors[1] = vec3(0.0, 1.0, 0.0);
    colors[2] = vec3(0.0, 0.0, 1.0);
    
    int idx = int(uv.x * 2.999);
    idx = clamp(idx, 0, 2);
    vec3 col = colors[idx] * sum;
    
    gl_FragColor = vec4(col, 1.0);
}
