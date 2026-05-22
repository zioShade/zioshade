// Tests: store-forward across multiple blocks with same variable
// Pattern: variable stored in one branch, loaded after merge
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float result;
    
    if (uv.x > 0.5) {
        result = uv.x * 2.0;
    } else {
        result = uv.y * 3.0;
    }
    
    // Use result after merge
    float a = result + 0.1;
    float b = result * 0.5;
    
    gl_FragColor = vec4(a, b, result, 1.0);
}
