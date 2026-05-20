#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x;
    float y = gl_FragCoord.y;
    vec3 a = vec3(x * 0.01, 0.0, 0.0);
    vec3 b = vec3(0.0, y * 0.01, 0.0);
    vec3 c = vec3(0.0, 0.0, 0.5);
    vec3 r = clamp(mix(a, b, 0.5) + c, 0.0, 1.0);
    r = mix(r, vec3(1.0), smoothstep(0.3, 0.7, length(r)));
    fragColor = vec4(r, 1.0);
}
