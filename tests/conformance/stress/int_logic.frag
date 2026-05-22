// Tests: integer comparison and logical operators
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    int a = int(uv.x * 10.0);
    int b = int(uv.y * 10.0);
    
    bool x = (a > 3) && (b < 7);
    bool y = (a == 5) || (b != 2);
    bool z = !(a < b);
    
    float r = x ? 1.0 : 0.0;
    float g = y ? 0.8 : 0.2;
    float b2 = z ? 0.6 : 0.4;
    
    gl_FragColor = vec4(r, g, b2, 1.0);
}
