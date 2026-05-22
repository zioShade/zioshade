// Tests: bool -> int conversion in arithmetic
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    bool a = uv.x > 0.5;
    bool b = uv.y > 0.5;
    
    // bool to int conversion
    int ai = int(a);  // 1 or 0
    int bi = int(b);
    
    // Arithmetic with bool-converted ints
    float sum = float(ai + bi);
    float prod = float(ai * bi);
    
    // Bool in ternary
    float sel = a ? uv.x : uv.y;
    
    gl_FragColor = vec4(sum * 0.5, prod, sel, 1.0);
}
