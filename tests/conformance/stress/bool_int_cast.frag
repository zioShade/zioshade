// Tests: bool(int) casts, int(bool) casts, implicit conversions
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    int a = 3;
    bool b = bool(a);     // non-zero -> true
    int c = int(b);       // true -> 1
    
    bool d = bool(0);     // false
    int e = int(d);       // 0
    
    float f1 = float(b);  // 1.0
    bool g = bool(0.0);   // false
    float f2 = float(g);  // 0.0
    
    // Use results
    float r = float(c) + f1 + f2;
    float gn = uv.y;
    float bl = float(e);
    
    gl_FragColor = vec4(r * 0.3, gn, bl + 0.5, 1.0);
}
