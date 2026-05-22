// Tests: complex array indexing patterns
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float data[8];
    for (int i = 0; i < 8; i++) {
        data[i] = hash(float(i) + uv.x * 100.0);
    }
    
    // Use computed indices
    int i1 = int(uv.x * 7.999);
    int i2 = (i1 + 3) % 8;
    int i3 = int(uv.y * 7.999);
    
    float r = data[i1];
    float g = data[i2];
    float b = data[i3];
    
    gl_FragColor = vec4(r, g, b, 1.0);
}

float hash(float n) {
    return fract(sin(n) * 43758.5453);
}
