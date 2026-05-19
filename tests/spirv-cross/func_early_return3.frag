#version 450
layout(location = 0) out vec4 FragColor;
float process(float x) {
    if (x < 0.25) return 0.1;
    if (x < 0.5) return 0.4;
    if (x < 0.75) return 0.7;
    return 1.0;
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float val = process(uv.x);
    FragColor = vec4(val, uv.y, 1.0 - val, 1.0);
}
