#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float t = uv.x;
    float s = sin(t * 6.28318530) * 0.5 + 0.5;
    float c = cos(t * 6.28318530) * 0.5 + 0.5;
    vec3 col = vec3(s, c, uv.y);
    FragColor = vec4(col, 1.0);
}
