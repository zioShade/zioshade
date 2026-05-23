#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // normalize, dot, cross, length, distance
    vec2 d = uv - vec2(0.5);
    float len = length(d);
    vec2 n = normalize(d + vec2(0.001));
    float dt = dot(n, vec2(1.0, 0.0));
    vec3 c = cross(vec3(d, 0.0), vec3(0.0, 0.0, 1.0));
    float dist = distance(uv, vec2(0.5));
    fragColor = vec4(dt, len, dist, 1.0);
}
