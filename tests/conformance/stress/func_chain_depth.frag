// Tests: function calling another function (call chain depth)
precision mediump float;
uniform vec2 u_resolution;

float noise(float x) {
    return fract(sin(x * 127.1) * 43758.5453);
}

float smooth(float x) {
    float i = floor(x);
    float f = fract(x);
    float t = f * f * (3.0 - 2.0 * f);
    return mix(noise(i), noise(i + 1.0), t);
}

float fbm(float x) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        val += amp * smooth(x);
        x *= 2.0;
        amp *= 0.5;
    }
    return val;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float n = fbm(uv.x * 10.0);
    
    vec3 col = vec3(n, n * 0.7, n * 0.3);
    gl_FragColor = vec4(col, 1.0);
}
