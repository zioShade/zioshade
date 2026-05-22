// Tests: function with multiple early returns
precision mediump float;
uniform vec2 u_resolution;

float classify(float x) {
    if (x < 0.0) return -1.0;
    if (x > 1.0) return 2.0;
    if (x == 0.5) return 0.5;
    return x * x;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float a = classify(uv.x - 0.5);
    float b = classify(uv.y);
    
    vec3 col = vec3(abs(a), abs(b), (a + b) * 0.25 + 0.5);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
