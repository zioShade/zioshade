#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 8.0;
    float v = sin(p.x * 1.3) * cos(p.y * 0.7) + sin(p.x * 0.5 + p.y * 1.1);
    float col = v * 0.5 + 0.5;
    gl_FragColor = vec4(0.0, col, 0.0, 1.0);
}
