// Tests: vertex shader with struct output and transformation
#version 450

layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;

layout(location = 0) out vec2 out_uv;

struct Transform {
    mat4 mvp;
    vec2 offset;
};

void main() {
    Transform t;
    t.mvp = mat4(1.0);
    t.offset = vec2(0.0);
    
    vec4 pos = t.mvp * vec4(in_pos + t.offset, 0.0, 1.0);
    gl_Position = pos;
    out_uv = in_uv;
}
