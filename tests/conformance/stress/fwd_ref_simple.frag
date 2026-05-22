// Tests: forward reference to function declared after main
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float v = compute(uv.x, uv.y); // forward ref
    gl_FragColor = vec4(vec3(fract(v)), 1.0);
}

float compute(float x, float y) {
    return sqrt(x * x + y * y);
}
