#version 450

// Test: discard in conditional
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float d = distance(uv, vec2(0.5));
    if (d > 0.5) discard;

    vec3 col = vec3(1.0 - d * 2.0);
    gl_FragColor = vec4(col, 1.0);
}
