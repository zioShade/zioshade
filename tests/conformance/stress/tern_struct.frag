// Tests: chained ternary with struct returns
precision mediump float;
uniform vec2 u_resolution;

struct Sample {
    float value;
    float weight;
};

Sample makeSample(float v, float w) {
    Sample s;
    s.value = v;
    s.weight = w;
    return s;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Sample s = uv.x > 0.5 ? makeSample(uv.x, 1.0) : makeSample(uv.y, 0.5);
    float result = s.value * s.weight;
    
    gl_FragColor = vec4(fract(result), fract(result * 0.7), 0.5, 1.0);
}
