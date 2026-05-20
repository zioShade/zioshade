#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy;
    float dist = length(uv - vec2(150.0));
    if (dist > 100.0) discard;
    float intensity = 1.0 - dist / 100.0;
    vec3 col = vec3(intensity);
    if (intensity < 0.2) {
        col = vec3(0.1, 0.0, 0.2);
    } else if (intensity < 0.5) {
        col = vec3(0.2, 0.1, 0.4);
    }
    fragColor = vec4(col, 1.0);
}
