// Tests: implicit conversions between int/uint/float
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // int to float (implicit)
    int i = 5;
    float f = float(i);
    
    // uint to float
    uint u = uint(uv.x * 100.0);
    float fu = float(u);
    
    // float to int
    int fi = int(uv.x * 10.0);
    
    // float to uint
    uint fu2 = uint(uv.y * 100.0);
    
    // Arithmetic with mixed types
    float r = float(fi) / 10.0;
    float g = fu / 100.0;
    float b = float(fu2 % 50u) / 50.0;
    
    gl_FragColor = vec4(fract(r), fract(g), fract(b), 1.0);
}
