// Tests: complex SDF pattern
#version 450
layout(location = 0) out vec4 fragColor;
uniform vec2 u_resolution;

float sdCircle(vec2 p, float r) {
    return length(p) - r;
}

float sdBox(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float scene(vec2 p) {
    float d1 = sdCircle(p - vec2(0.3), 0.2);
    float d2 = sdBox(p - vec2(-0.3), vec2(0.15));
    return min(d1, d2);
}

void main() {
    vec2 uv = (gl_FragCoord.xy / u_resolution - 0.5) * 2.0;
    float d = scene(uv);
    vec3 color = vec3(1.0 - smoothstep(0.0, 0.02, d));
    color *= 1.0 - d * 2.0;
    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
