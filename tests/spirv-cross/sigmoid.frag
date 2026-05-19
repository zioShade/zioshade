#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x * 6.0 - 3.0;
    float sig = 1.0 / (1.0 + exp(-x));
    gl_FragColor = vec4(sig, uv.y, 1.0 - sig, 1.0);
}
