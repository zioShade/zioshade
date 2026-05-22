// Tests: partially initialized variable across many branches
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float a; // uninitialized
    float b; // uninitialized
    float c; // uninitialized
    
    float threshold = uv.x;
    
    if (threshold > 0.75) {
        a = 1.0;
        b = 0.5;
        c = 0.25;
    } else if (threshold > 0.5) {
        a = 0.8;
        b = 0.3;
        // c not set
    } else if (threshold > 0.25) {
        a = 0.4;
        // b, c not set
    } else {
        a = 0.1;
        b = 0.1;
        c = 0.1;
    }
    
    // Use a (always initialized), b and c may be uninitialized
    float result = a + (uv.y > 0.5 ? b : c);
    
    gl_FragColor = vec4(vec3(result * 0.5), 1.0);
}
