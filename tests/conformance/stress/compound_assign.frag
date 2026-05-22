// Tests: compound assignment operators on different types
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float a = 0.5;
    a += uv.x;
    a -= 0.1;
    a *= 2.0;
    a /= 3.0;
    
    vec3 v = vec3(0.1);
    v += vec3(uv.x, uv.y, 0.5);
    v *= vec3(0.5, 1.0, 1.5);
    v -= vec3(0.05);
    
    int i = 5;
    i += 3;
    i -= 1;
    i *= 2;
    i /= 3;
    
    float r = a;
    float g = v.x + v.y;
    float b = float(i) * 0.05;
    
    gl_FragColor = vec4(r, g, b, 1.0);
}
