#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float wave = sin(uv.x * 20.0 + uv.y * 10.0) * 0.5 + 0.5;
    float wave2 = cos(uv.x * 15.0 - uv.y * 8.0) * 0.5 + 0.5;
    vec3 col = vec3(wave * 0.7, wave2 * 0.5, (wave + wave2) * 0.3);
    FragColor = vec4(col, 1.0);
}
