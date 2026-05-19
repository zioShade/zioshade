#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 incident = uv * 2.0 - 1.0;
    vec2 normal = vec2(0.0, 1.0);
    vec2 ref = reflect(incident, normal);
    vec2 refr = refract(incident, normal, 0.5);
    FragColor = vec4(ref * 0.5 + 0.5, refr * 0.5 + 0.5);
}
