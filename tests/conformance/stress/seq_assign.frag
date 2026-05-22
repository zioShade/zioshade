// Tests: precise qualifier and multiple assignments to same variable
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Sequential assignments to same variable
    float val = uv.x;
    val = val * 2.0;
    val = val - 0.5;
    val = clamp(val, 0.0, 1.0);
    
    // Assign from ternary
    val = val > 0.5 ? 1.0 - val : val * 2.0;
    
    // Assign from function-like expression
    val = fract(val * 3.0);
    
    gl_FragColor = vec4(vec3(val), 1.0);
}
