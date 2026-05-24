// Tests: vertex shader with position output
#version 450
uniform mat4 u_mvp;

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec2 inUV;

void main() {
    gl_Position = u_mvp * vec4(inPos, 1.0);
}
