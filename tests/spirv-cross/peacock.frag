#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Peacock feather
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Eye spot
    float eye_outer = smoothstep(0.25, 0.22, r) * (1.0 - smoothstep(0.18, 0.15, r));
    float eye_inner = smoothstep(0.1, 0.08, r) * (1.0 - smoothstep(0.05, 0.03, r));
    // Barbules (fine lines radiating outward)
    float barbs = sin(a * 40.0) * 0.5 + 0.5;
    barbs *= smoothstep(0.3, 0.5, r) * (1.0 - smoothstep(0.9, 1.0, r));
    vec3 green = vec3(0.1, 0.5, 0.2);
    vec3 blue = vec3(0.1, 0.2, 0.6);
    vec3 gold = vec3(0.8, 0.7, 0.2);
    vec3 dark = vec3(0.02);
    vec3 col = vec3(0.05, 0.1, 0.05) + green * barbs;
    col = mix(col, gold, eye_outer);
    col = mix(col, blue, eye_inner);
    col = mix(col, dark, smoothstep(0.03, 0.015, r));
    fragColor = vec4(col, 1.0);
}
