#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Cat face
    float r = length(uv);
    // Head
    float head = smoothstep(0.65, 0.62, r);
    // Ears (triangles)
    float ear_l = smoothstep(0.02, 0.01, max(
        max(-(uv.x + 0.45), (uv.x + 0.45) - (uv.y - 0.5)),
        -(uv.y - 0.5))
    );
    float ear_r = smoothstep(0.02, 0.01, max(
        max((uv.x - 0.45), -(uv.x - 0.45) - (uv.y - 0.5)),
        -(uv.y - 0.5))
    );
    // Eyes
    float eye_l = smoothstep(0.08, 0.06, length(uv - vec2(-0.2, 0.1)));
    float eye_r = smoothstep(0.08, 0.06, length(uv - vec2(0.2, 0.1)));
    // Pupils
    float pupil_l = smoothstep(0.04, 0.02, length(uv - vec2(-0.2, 0.1)));
    float pupil_r = smoothstep(0.04, 0.02, length(uv - vec2(0.2, 0.1)));
    // Nose
    float nose = smoothstep(0.03, 0.02, length(uv - vec2(0.0, -0.05)));
    // Mouth
    float mouth = smoothstep(0.01, 0.005, abs(uv.y + 0.12)) * step(abs(uv.x), 0.1);
    vec3 orange = vec3(0.9, 0.6, 0.2);
    vec3 dark = vec3(0.1);
    vec3 pink = vec3(0.9, 0.6, 0.6);
    vec3 col = vec3(0.05);
    col = mix(col, orange, head + ear_l + ear_r);
    col = mix(col, vec3(1.0), eye_l + eye_r - pupil_l - pupil_r);
    col = mix(col, dark, pupil_l + pupil_r);
    col = mix(col, pink, nose);
    col += vec3(0.3) * mouth;
    fragColor = vec4(col, 1.0);
}
