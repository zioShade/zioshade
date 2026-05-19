#version 450

// Test: vec3 face from normal with shading
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 2.0 - 1.0;

    // Compute normal from derivatives
    vec3 dx = dFdx(vec3(p, 0.0));
    vec3 dy = dFdy(vec3(p, 0.0));
    vec3 normal = normalize(cross(dx, dy));

    vec3 light = normalize(vec3(1.0, 1.0, 1.0));
    float diff = max(dot(normal, light), 0.0);

    vec3 col = abs(normal) * (diff * 0.7 + 0.3);
    gl_FragColor = vec4(col, 1.0);
}
