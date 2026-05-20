#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    // Simple eye: iris + pupil + highlight
    float iris = smoothstep(0.35, 0.33, r);
    float pupil = smoothstep(0.15, 0.13, r);
    float highlight = smoothstep(0.06, 0.04, length(uv - vec2(0.08, 0.08)));
    vec3 iris_col = mix(vec3(0.2, 0.5, 0.3), vec3(0.1, 0.3, 0.15), r / 0.35);
    vec3 col = vec3(0.95, 0.93, 0.9); // white of eye
    col = mix(col, iris_col, iris);
    col = mix(col, vec3(0.02), pupil);
    col = mix(col, vec3(1.0), highlight * 0.8);
    fragColor = vec4(col, 1.0);
}
