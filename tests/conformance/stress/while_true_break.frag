// Tests: while(true) loop with multiple break conditions
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float x = uv.x;
    float y = uv.y;
    int count = 0;
    
    while (true) {
        x = x * x - y * y + uv.x;
        y = 2.0 * x * y + uv.y;
        count++;
        
        if (x * x + y * y > 4.0) break;
        if (count >= 20) break;
    }
    
    float r = float(count) / 20.0;
    float g = fract(x);
    float b = fract(y);
    
    gl_FragColor = vec4(r, g, b, 1.0);
}
