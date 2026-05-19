#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float val = 0.0;
    if (uv.x > 0.3) val = 0.5;
    if (uv.y > 0.6) val = 0.8;
    if (uv.x + uv.y > 1.0) val = 1.0;
    FragColor = vec4(val, val * uv.y, val * uv.x, 1.0);
}
