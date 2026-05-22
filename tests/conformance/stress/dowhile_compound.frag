// Tests: do-while loop with compound exit condition
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float x = uv.x;
    int iter = 0;
    float prev = 0.0;
    
    do {
        prev = x;
        x = x * x - 0.5;
        iter++;
    } while (abs(x - prev) > 0.001 && iter < 20);
    
    float r = float(iter) / 20.0;
    float g = abs(x);
    float b = fract(prev);
    
    gl_FragColor = vec4(r, g, b, 1.0);
}
