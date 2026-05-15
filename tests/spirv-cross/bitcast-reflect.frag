#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test bitcast operations
    float a = uv.x;
    uint b = floatBitsToUint(a);
    float c = uintBitsToFloat(b);
    int d = floatBitsToInt(c);
    float e = intBitsToFloat(d);

    // Test vector shuffles
    vec4 v = vec4(1, 2, 3, 4);
    vec4 w = v.wzyx;

    // Test cross product
    vec3 n = normalize(vec3(uv, 0.5));
    vec3 light = normalize(vec3(1.0, 1.0, 1.0));
    vec3 reflected = reflect(-light, n);

    fragColor = vec4(e, w.x / 4.0, reflected.z, 1.0);
}
