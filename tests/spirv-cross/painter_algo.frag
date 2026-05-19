#version 450

// Test: face depth ordering with painter's algorithm
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    // Two overlapping circles
    float d1 = length(uv - vec2(0.4, 0.5));
    float d2 = length(uv - vec2(0.6, 0.5));

    vec3 col = vec3(0.1);
    if (d1 < 0.3) col = vec3(0.8, 0.3, 0.2); // red circle
    if (d2 < 0.3) col = vec3(0.2, 0.3, 0.8); // blue circle on top

    gl_FragColor = vec4(col, 1.0);
}
