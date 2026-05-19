#version 430
layout(location = 0) out vec4 FragColor;

// Test: reflect and refract
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 incident = normalize(uv * 2.0 - 1.0);
    vec2 normal = vec2(0.0, 1.0);

    vec2 ref = reflect(incident, normal);
    vec2 refr = refract(incident, normal, 0.7);

    FragColor = vec4(ref * 0.5 + 0.5, refr * 0.5 + 0.5);
}
