#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mat4 operations
void main() {
    float angle = uv.x * 3.14159;
    float c = cos(angle);
    float s = sin(angle);
    
    // 4x4 rotation around Y
    mat4 rotY = mat4(
         c, 0.0,  s, 0.0,
        0.0, 1.0, 0.0, 0.0,
        -s, 0.0,  c, 0.0,
        0.0, 0.0, 0.0, 1.0
    );
    
    // 4x4 rotation around X
    mat4 rotX = mat4(
        1.0, 0.0, 0.0, 0.0,
        0.0,  c, -s, 0.0,
        0.0,  s,  c, 0.0,
        0.0, 0.0, 0.0, 1.0
    );
    
    vec4 v = vec4(uv.y, 0.5, 0.3, 1.0);
    vec4 result = rotX * rotY * v;
    
    fragColor = vec4(result.xy, result.z * 0.5 + 0.5, 1.0);
}
