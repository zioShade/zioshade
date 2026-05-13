#version 430
layout(location = 0) out vec4 FragColor;

vec3 heatmap(float t) {
    return mix(vec3(0.0, 0.0, 1.0), vec3(1.0, 0.0, 0.0), t);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float d = length(uv - vec2(0.5));
    vec3 col = heatmap(clamp(d * 2.0, 0.0, 1.0));
    FragColor = vec4(col, 1.0);
}
