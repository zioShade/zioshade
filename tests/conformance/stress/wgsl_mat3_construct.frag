// Tests: matrix construction from vectors
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec3 x_axis = vec3(1.0, 0.0, 0.0);
    vec3 y_axis = vec3(0.0, cos(0.5), sin(0.5));
    vec3 z_axis = vec3(0.0, -sin(0.5), cos(0.5));
    mat3 rot = mat3(x_axis, y_axis, z_axis);

    vec3 v = vec3(1.0, 1.0, 1.0);
    vec3 transformed = rot * v;
    fragColor = vec4(clamp(transformed, 0.0, 1.0), 1.0);
}
