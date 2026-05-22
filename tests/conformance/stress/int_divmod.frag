// Tests: integer division and modulo operations
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    int a = int(uv.x * 20.0);
    int b = int(uv.y * 7.0) + 1;
    
    int div = a / b;
    int mod = a - (a / b) * b;  // manual modulo since GLSL ES % is limited
    int rem = a % b;
    
    float r = float(div) * 0.1;
    float g = float(rem) * 0.15;
    float b2 = float(mod) * 0.2;
    
    gl_FragColor = vec4(fract(r), fract(g), fract(b2 + 0.3), 1.0);
}
