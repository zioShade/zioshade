// Test: vertex shader with instancing
#version 450

layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec2 aTexCoord;
layout(location = 2) in vec3 aNormal;

layout(binding = 0) uniform UBO {
    mat4 mvp;
    mat4 model;
    float time;
};

layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out vec3 vNormal;

void main() {
    int instance = gl_InstanceID;
    float angle = float(instance) * 0.5 + time;
    
    float c = cos(angle);
    float s = sin(angle);
    mat3 rot = mat3(
        c, 0.0, s,
        0.0, 1.0, 0.0,
        -s, 0.0, c
    );
    
    vec3 rotated = rot * aPosition;
    float offset = float(instance) * 2.0;
    rotated.x += offset;
    
    gl_Position = mvp * vec4(rotated, 1.0);
    vTexCoord = aTexCoord;
    vNormal = (model * vec4(aNormal, 0.0)).xyz;
}
