// Tests: multiple switch statements in sequence
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float r = 0.0;
    int mode1 = int(uv.x * 4.0) % 4;
    switch (mode1) {
        case 0: r = 0.2; break;
        case 1: r = 0.4; break;
        case 2: r = 0.6; break;
        case 3: r = 0.8; break;
    }
    
    float g = 0.0;
    int mode2 = int(uv.y * 3.0) % 3;
    switch (mode2) {
        case 0: g = 0.3; break;
        case 1: g = 0.5; break;
        case 2: g = 0.7; break;
    }
    
    float b = mix(r, g, 0.5);
    gl_FragColor = vec4(r, g, b, 1.0);
}
