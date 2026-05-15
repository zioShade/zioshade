#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test mat3 from integer literals (implicit int→float conversion)
    mat3 a = mat3(1,0,0, 0,1,0, 0,0,1);
    vec3 v1 = a * vec3(uv, 1.0);

    // Test mat3 from int scalar (diagonal identity)
    mat3 b = mat3(2);
    vec3 v2 = b * vec3(1.0);

    // Test mat4 from mixed int/float scalars
    mat4 c = mat4(1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1);
    vec4 v3 = c * vec4(uv, 0.0, 1.0);

    fragColor = vec4(v1.xy, v2.z, v3.w);
}
