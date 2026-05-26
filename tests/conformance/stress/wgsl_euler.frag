// Test: euler angle rotation composition
#version 450

layout(location = 0) out vec4 fragColor;

mat3 rotationX(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return mat3(1.0, 0.0, 0.0, 0.0, c, s, 0.0, -s, c);
}

mat3 rotationY(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return mat3(c, 0.0, -s, 0.0, 1.0, 0.0, s, 0.0, c);
}

mat3 rotationZ(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return mat3(c, s, 0.0, -s, c, 0.0, 0.0, 0.0, 1.0);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    mat3 rx = rotationX(uv.x * 3.14);
    mat3 ry = rotationY(uv.y * 3.14);
    mat3 rz = rotationZ(1.57);
    
    mat3 combined = rz * ry * rx;
    vec3 p = combined * vec3(0.0, 0.0, 1.0);
    
    fragColor = vec4(p * 0.5 + 0.5, 1.0);
}
