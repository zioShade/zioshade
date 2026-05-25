// Tests: multiple uniforms in struct
#version 450
layout(location = 0) out vec4 fragColor;

struct Light {
    vec3 position;
    vec3 color;
    float intensity;
};
uniform Light u_light;
uniform vec3 u_surfacePos;

void main() {
    vec3 toLight = u_light.position - u_surfacePos;
    float dist = length(toLight);
    float atten = u_light.intensity / (dist * dist + 1.0);
    vec3 color = u_light.color * atten;
    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
