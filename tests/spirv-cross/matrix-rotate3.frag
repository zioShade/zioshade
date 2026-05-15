#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test matrix operations
    mat3 m = mat3(
        1.0, 0.0, 0.0,
        0.0, cos(u), -sin(u),
        0.0, sin(u), cos(u)
    );
    vec3 v = vec3(1.0, 0.5, 0.25);
    vec3 result = m * v;
    float det = result.x + result.y + result.z;
    fragColor = vec4(result / max(det, 0.001), 1.0);
}
