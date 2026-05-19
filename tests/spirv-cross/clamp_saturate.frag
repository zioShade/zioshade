#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float val = (uv.x - 0.5) * 3.0;
    float clamped = clamp(val, 0.0, 1.0);
    float min_val = min(uv.x, uv.y);
    float max_val = max(uv.x, uv.y);
    FragColor = vec4(clamped, min_val, max_val, 1.0);
}
