#version 450
layout(location = 0) out vec4 FragColor;
vec3 heatmap(float t) {
    if (t < 0.25) return mix(vec3(0.0, 0.0, 0.5), vec3(0.0, 0.5, 1.0), t * 4.0);
    if (t < 0.5) return mix(vec3(0.0, 0.5, 1.0), vec3(0.0, 1.0, 0.0), (t - 0.25) * 4.0);
    if (t < 0.75) return mix(vec3(0.0, 1.0, 0.0), vec3(1.0, 1.0, 0.0), (t - 0.5) * 4.0);
    return mix(vec3(1.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), (t - 0.75) * 4.0);
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = heatmap(uv.x);
    col *= smoothstep(0.2, 0.8, uv.y);
    FragColor = vec4(col, 1.0);
}
