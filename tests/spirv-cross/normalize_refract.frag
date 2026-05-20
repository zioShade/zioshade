#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy;
    vec3 incident = normalize(vec3(uv - 150.0, 100.0));
    vec3 normal = vec3(0.0, 0.0, 1.0);
    vec3 reflected = reflect(incident, normal);
    vec3 refracted = refract(incident, normal, 0.8);
    float fresnel = 1.0 - abs(dot(incident, normal));
    vec3 col = mix(refracted, reflected, fresnel);
    fragColor = vec4(col * 0.5 + 0.5, 1.0);
}
