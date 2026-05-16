#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Tri-planar mapping
    vec3 p = vec3(uv * 3.0, uv.x + uv.y);

    // Simulated tri-planar blending
    vec3 blend = normalize(abs(p));
    blend /= (blend.x + blend.y + blend.z);

    float x_plane = fract(p.y * 4.0);
    float y_plane = fract(p.z * 4.0);
    float z_plane = fract(p.x * 4.0);

    float pattern = blend.x * x_plane + blend.y * y_plane + blend.z * z_plane;

    vec3 col = vec3(pattern, pattern * 0.8, pattern * 0.6);
    fragColor = vec4(col, 1.0);
}
