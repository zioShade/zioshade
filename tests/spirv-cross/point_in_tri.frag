#version 450

// Test: face-based coloring using sign of cross product
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 a = vec2(0.3, 0.7);
    vec2 b = vec2(0.7, 0.3);
    vec2 c = vec2(0.5, 0.8);

    vec2 pa = uv - a;
    vec2 pb = uv - b;
    vec2 pc = uv - c;

    float cross_ab = pa.x * pb.y - pa.y * pb.x;
    float cross_bc = pb.x * pc.y - pb.y * pc.x;
    float cross_ca = pc.x * pa.y - pc.y * pa.x;

    bool inside = (cross_ab > 0.0 && cross_bc > 0.0 && cross_ca > 0.0) ||
                  (cross_ab < 0.0 && cross_bc < 0.0 && cross_ca < 0.0);

    vec3 col = inside ? vec3(1.0, 0.8, 0.2) : vec3(0.1, 0.1, 0.2);
    gl_FragColor = vec4(col, 1.0);
}
