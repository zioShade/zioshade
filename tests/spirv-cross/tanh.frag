#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x * 4.0 - 2.0;
    float th = tanh(x) * 0.5 + 0.5;
    gl_FragColor = vec4(th, uv.y, 1.0 - th, 1.0);
}
