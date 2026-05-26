// Test: vertex shader with conditional output
#version 450

layout(location = 0) in vec3 aPos;
layout(location = 1) in float aFlag;

layout(binding = 0) uniform UBO {
    mat4 mvp;
    float time;
    int mode;
};

layout(location = 0) out vec3 vColor;
layout(location = 1) out float vFlag;

void main() {
    vec3 pos = aPos;
    
    if (mode == 0) {
        pos.y += sin(time + aPos.x * 3.0) * 0.1;
    } else if (mode == 1) {
        pos.x += cos(time + aPos.z * 2.0) * 0.1;
    }
    
    gl_Position = mvp * vec4(pos, 1.0);
    vColor = pos * 0.5 + 0.5;
    vFlag = aFlag;
}
