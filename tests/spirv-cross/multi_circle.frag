#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = vec3(0.1);
    float d1 = length(uv - vec2(0.3, 0.5));
    float d2 = length(uv - vec2(0.7, 0.5));
    float d3 = length(uv - vec2(0.5, 0.3));
    col = mix(col, vec3(1.0, 0.2, 0.2), smoothstep(0.15, 0.14, d1));
    col = mix(col, vec3(0.2, 1.0, 0.2), smoothstep(0.15, 0.14, d2));
    col = mix(col, vec3(0.2, 0.2, 1.0), smoothstep(0.15, 0.14, d3));
    FragColor = vec4(col, 1.0);
}
