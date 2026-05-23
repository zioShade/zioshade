#version 450
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    // step function — creates sharp edges
    float s1 = step(0.5, uv.x);
    float s2 = step(0.5, uv.y);
    vec3 col = vec3(s1, s2, s1 * s2);
    fragColor = vec4(col, 1.0);
}
