// Tests: global variable initializers and multiple functions using them
precision mediump float;
uniform vec2 u_resolution;

const float PI = 3.14159265;
const float TWO_PI = 6.28318530;

float wave(float x, float freq, float phase) {
    return sin(x * freq + phase) * 0.5 + 0.5;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float r = wave(uv.x, PI, 0.0);
    float g = wave(uv.y, TWO_PI, PI * 0.5);
    float b = wave(uv.x + uv.y, 4.0, 1.0);
    
    gl_FragColor = vec4(r, g, b, 1.0);
}
