#version 430
layout(location = 0) out vec4 FragColor;

// Test: wave interference
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float d1 = distance(uv, vec2(0.3, 0.3));
    float d2 = distance(uv, vec2(0.7, 0.7));
    float w1 = sin(d1 * 40.0);
    float w2 = sin(d2 * 40.0);

    float interference = (w1 + w2) * 0.5;
    vec3 col = vec3(interference * 0.5 + 0.5);
    FragColor = vec4(col, 1.0);
}
