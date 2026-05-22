// Tests: float to int to float conversions with negative values
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution - 0.5;
    
    float a = uv.x * -3.0;
    int i = int(a);           // negative float -> int
    float b = float(i);       // int -> float
    int j = int(floor(a));    // floor then int
    float c = float(j);
    
    // unsigned
    uint u = uint(a + 10.0);  // positive offset, then uint
    float d = float(u);
    
    float r = fract(b + 5.0);
    float g = fract(c + 5.0);
    float b2 = fract(d / 20.0);
    
    gl_FragColor = vec4(r, g, b2, 1.0);
}
