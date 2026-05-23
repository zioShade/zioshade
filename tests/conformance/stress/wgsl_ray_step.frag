#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // Struct construction and access
    vec3 pos = vec3(uv, 0.0);
    vec3 dir = normalize(vec3(1.0, 1.0, 1.0));
    float dt = 0.1;
    vec3 p = pos + dir * dt;
    float t = length(p) / length(pos + vec3(1.0));
    fragColor = vec4(vec3(t), 1.0);
}
