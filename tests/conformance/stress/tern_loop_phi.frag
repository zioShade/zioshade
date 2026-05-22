// Tests: phi node from ternary chain feeding into loop
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float x = uv.x > 0.5 ? uv.x : 1.0 - uv.x;
    float y = uv.y > 0.3 ? uv.y * 2.0 : uv.y * 0.5;
    
    // Use ternary result in loop accumulator
    float acc = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        acc += x * fi + y * fi * fi;
        x = fract(x + 0.1);
    }
    
    gl_FragColor = vec4(vec3(fract(acc * 0.1)), 1.0);
}
