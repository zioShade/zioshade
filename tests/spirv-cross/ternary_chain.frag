#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float val = uv.x < 0.25 ? 0.2 : (uv.x < 0.5 ? 0.4 : (uv.x < 0.75 ? 0.7 : 1.0));
    val *= smoothstep(0.2, 0.8, uv.y);
    FragColor = vec4(val, 0.0, 1.0 - val, 1.0);
}
