// Tests: vertex shader with instancing
#version 450
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aOffset;
layout(location = 0) out vec3 vColor;
uniform mat4 u_viewProj;

void main() {
    vec3 worldPos = aPos + aOffset;
    gl_Position = u_viewProj * vec4(worldPos, 1.0);
    vColor = aPos + 0.5;
}
