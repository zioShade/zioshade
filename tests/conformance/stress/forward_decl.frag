// Tests: forward-declared function called before definition
precision mediump float;
uniform vec2 u_resolution;

float process(float x);

float enhance(float x) {
    return process(x) * 2.0;
}

float process(float x) {
    return x * x + 1.0;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float a = enhance(uv.x);
    float b = process(uv.y);
    
    vec3 col = vec3(a * 0.2, b * 0.1, (a + b) * 0.05);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
