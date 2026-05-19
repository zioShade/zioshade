#version 450

// Test: conditional discard with smoothstep mask
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float mask = smoothstep(0.3, 0.32, length(uv - 0.5));

    vec3 col = vec3(uv, 0.5) * mask;
    gl_FragColor = vec4(col, 1.0);
}
