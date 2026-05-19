#version 450

// Test: vec3 cross product applications
vec3 computeNormal(vec2 uv) {
    vec3 a = vec3(1.0, 0.0, 0.0);
    vec3 b = vec3(0.0, 1.0, 0.0);
    vec3 n = normalize(cross(a, b));

    // Perturb normal based on UV
    n.x += sin(uv.x * 10.0) * 0.3;
    n.y += cos(uv.y * 10.0) * 0.3;
    return normalize(n);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 normal = computeNormal(uv);
    vec3 light = normalize(vec3(1.0, 1.0, 1.0));
    float diffuse = max(dot(normal, light), 0.0);
    vec3 col = vec3(0.6, 0.7, 0.8) * (diffuse * 0.7 + 0.3);
    gl_FragColor = vec4(col, 1.0);
}
