#version 450

// Test: vec3 face coloring based on normal direction
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 p = vec3(uv * 2.0 - 1.0, 0.5);
    vec3 normal = normalize(p);

    // Color based on normal direction
    vec3 col = vec3(
        abs(normal.x),
        abs(normal.y),
        abs(normal.z)
    );

    gl_FragColor = vec4(col, 1.0);
}
