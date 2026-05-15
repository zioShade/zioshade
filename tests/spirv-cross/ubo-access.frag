#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// UBO access — exercises uniform buffer objects, struct member access
layout(std140, binding = 0) uniform Params {
    float scale;
    float offset;
    vec3 color;
};

void main() {
    float v = uv.x * scale + offset;
    fragColor = vec4(color * v, 1.0);
}
