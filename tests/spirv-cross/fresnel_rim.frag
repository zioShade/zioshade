#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float d = length(uv);
    // Fresnel effect
    float fresnel = pow(1.0 - abs(dot(normalize(vec3(uv, 0.5)), vec3(0.0, 0.0, 1.0))), 3.0);
    vec3 base = vec3(0.1, 0.2, 0.4);
    vec3 rim = vec3(0.5, 0.8, 1.0);
    vec3 col = mix(base, rim, fresnel);
    col *= smoothstep(1.2, 0.8, d);
    fragColor = vec4(col, 1.0);
}
