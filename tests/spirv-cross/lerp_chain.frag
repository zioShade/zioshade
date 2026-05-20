#version 310 es
precision highp float;
out vec4 fragColor;

vec3 lerp3(vec3 a, vec3 b, float t) {
    return mix(a, b, t);
}

void main() {
    float t = gl_FragCoord.x * 0.005;
    vec3 a = vec3(1.0, 0.0, 0.0);
    vec3 b = vec3(0.0, 1.0, 0.0);
    vec3 c = vec3(0.0, 0.0, 1.0);
    vec3 d = vec3(1.0, 1.0, 0.0);
    vec3 r1 = lerp3(a, b, t);
    vec3 r2 = lerp3(b, c, t);
    vec3 r3 = lerp3(r1, r2, t);
    vec3 r4 = lerp3(r3, d, t * 0.5);
    fragColor = vec4(r4, 1.0);
}
