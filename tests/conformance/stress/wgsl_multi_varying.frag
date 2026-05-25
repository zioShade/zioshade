// Tests: fragment with multiple input varyings
#version 450
layout(location = 0) in vec3 vNormal;
layout(location = 1) in vec3 vWorldPos;
layout(location = 2) in vec2 vUV;
layout(location = 0) out vec4 fragColor;

void main() {
    vec3 lightDir = normalize(vec3(1.0, 1.0, 1.0));
    float NdotL = max(dot(normalize(vNormal), lightDir), 0.0);
    vec3 baseColor = vec3(vUV, 0.5);
    vec3 color = baseColor * (NdotL * 0.8 + 0.2);
    fragColor = vec4(color, 1.0);
}
