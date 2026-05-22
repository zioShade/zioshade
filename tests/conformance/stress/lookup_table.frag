// Tests: complex loop with array used as lookup table
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Build a lookup table of sin values
    float sinTable[16];
    for (int i = 0; i < 16; i++) {
        sinTable[i] = sin(float(i) * 0.3927) * 0.5 + 0.5; // sin(i * PI/8)
    }
    
    // Use it for color mapping
    int idx1 = int(uv.x * 15.999);
    int idx2 = int(uv.y * 15.999);
    idx1 = clamp(idx1, 0, 15);
    idx2 = clamp(idx2, 0, 15);
    
    float r = sinTable[idx1];
    float g = sinTable[idx2];
    float b = sinTable[(idx1 + idx2) / 2];
    
    gl_FragColor = vec4(r, g, b, 1.0);
}
