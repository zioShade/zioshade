#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float cx = smoothstep(0.02, 0.01, abs(uv.x - 0.5));
    float cy = smoothstep(0.02, 0.01, abs(uv.y - 0.5));
    float cross = max(cx, cy);
    float ring = smoothstep(0.01, 0.0, abs(length(uv - 0.5) - 0.2));
    float mask = max(cross, ring);
    vec3 col = mix(vec3(0.1), vec3(0.9, 0.2, 0.1), mask);
    gl_FragColor = vec4(col, 1.0);
}
