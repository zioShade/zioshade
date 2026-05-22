// Tests: nested ternary chains with function calls
precision mediump float;
uniform vec2 u_resolution;

float hash(float n) {
    return fract(sin(n) * 43758.5453);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float h = hash(uv.x * 100.0 + uv.y * 57.0);
    
    // Chained ternary with function calls in each branch
    float val = h < 0.25 ? hash(h * 10.0) :
                h < 0.50 ? hash(h * 20.0 + 1.0) :
                h < 0.75 ? hash(h * 30.0 + 2.0) :
                           hash(h * 40.0 + 3.0);
    
    vec3 col = vec3(val, val * 0.7, val * 0.3);
    gl_FragColor = vec4(col, 1.0);
}
