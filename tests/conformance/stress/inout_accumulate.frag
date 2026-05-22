// Tests: recursive-style accumulation with inout param and break
precision mediump float;
uniform vec2 u_resolution;

void accumulate(inout float sum, inout float prev, float x) {
    float delta = x - prev;
    sum += delta * delta;
    prev = x;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float sum = 0.0;
    float prev = 0.0;
    
    for (int i = 0; i < 10; i++) {
        float x = hash(float(i) * 0.37 + uv.x) + uv.y * 0.1;
        accumulate(sum, prev, x);
        if (sum > 2.0) break;
    }
    
    gl_FragColor = vec4(vec3(fract(sum)), 1.0);
}

float hash(float n) {
    return fract(sin(n) * 43758.5453);
}
