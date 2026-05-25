// Tests: reflection and refraction
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec3 incident = normalize(vec3(1.0, -1.0, 0.0));
    vec3 normal = vec3(0.0, 1.0, 0.0);
    vec3 refl = reflect(incident, normal);
    vec3 refr = refract(incident, normal, 0.5);
    float fresnel = 1.0 - abs(dot(incident, normal));
    vec3 color = mix(refr, refl, fresnel);
    fragColor = vec4(color * 0.5 + 0.5, 1.0);
}
