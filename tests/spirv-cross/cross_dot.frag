#version 450

// Test: face determinant and cross product in 2D/3D
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    vec3 a = vec3(1.0, 0.0, 0.0);
    vec3 b = vec3(0.0, 1.0, 0.0);
    vec3 c = cross(a, b);
    vec3 d = cross(b, a);

    float dot_ab = dot(a, b);
    float dot_ac = dot(a, c);
    float len_c = length(c);

    vec2 p1 = uv;
    vec2 p2 = vec2(0.5, 0.8);
    float cross2d = p1.x * p2.y - p1.y * p2.x;

    gl_FragColor = vec4(dot_ac, len_c, cross2d, 1.0);
}
