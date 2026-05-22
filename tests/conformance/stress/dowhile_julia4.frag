// Tests: do-while loop with break and float tracking
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float z = uv.x * 2.0 - 1.0;
    int iter = 0;
    float last_z = 0.0;
    
    do {
        last_z = z;
        z = z * z + uv.y - 0.5;
        iter++;
    } while (iter < 20 && abs(z) < 10.0);
    
    float r = float(iter) / 20.0;
    float g = abs(last_z) * 0.1;
    float b = abs(z) * 0.05;
    
    gl_FragColor = vec4(clamp(vec3(r, g, b), 0.0, 1.0), 1.0);
}
