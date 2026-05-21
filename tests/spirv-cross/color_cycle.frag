#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Test: multiple vec constructors in complex expression
    vec3 a = vec3(1.0, 0.0, 0.0);
    vec3 b = vec3(0.0, 1.0, 0.0);
    vec3 c = vec3(0.0, 0.0, 1.0);
    float t = length(uv);
    // Interpolate through 3 colors
    vec3 col;
    if (t < 0.33) {
        col = mix(a, b, t * 3.0);
    } else if (t < 0.66) {
        col = mix(b, c, (t - 0.33) * 3.0);
    } else {
        col = mix(c, a, (t - 0.66) * 3.0);
    }
    fragColor = vec4(col, 1.0);
}
