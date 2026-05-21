#version 310 es
precision highp float;
out vec4 fragColor;

vec3 pal4(float t) {
    return vec3(
        cos(t * 6.28) * 0.5 + 0.5,
        cos(t * 6.28 + 2.09) * 0.5 + 0.5,
        cos(t * 6.28 + 4.18) * 0.5 + 0.5
    );
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    // Forward ref with vec3 cos
    vec3 col = pal4(r * 3.0);
    col *= smoothstep(1.0, 0.3, r);
    fragColor = vec4(col, 1.0);
}
