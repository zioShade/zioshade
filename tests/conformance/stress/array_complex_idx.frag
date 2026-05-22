// Tests: complex expression in array index + assignment to array element
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float grid[4];
    for (int i = 0; i < 4; i++) {
        grid[i] = 0.0;
    }
    
    // Dynamic index with complex expression
    int a = int(uv.x * 3.999);
    int b = int(uv.y * 3.999);
    a = clamp(a, 0, 3);
    b = clamp(b, 0, 3);
    
    grid[a] += 0.5;
    grid[b] += 0.3;
    
    // Read back with another dynamic index
    int c = (a + b) % 4;
    float result = grid[c] + grid[a] * 0.5;
    
    gl_FragColor = vec4(vec3(fract(result)), 1.0);
}
