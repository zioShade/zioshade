#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float arr[3];
    arr[0] = 0.2;
    arr[1] = 0.5;
    arr[2] = 0.8;
    int idx = int(uv.x * 2.999);
    idx = clamp(idx, 0, 2);
    float val = arr[idx];
    FragColor = vec4(val, uv.y, 1.0 - val, 1.0);
}
