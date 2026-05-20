#version 310 es
precision highp float;
out vec4 fragColor;

// IQ palette function (forward reference)
vec3 iq_palette(float t, vec3 a, vec3 b, vec3 c, vec3 d) {
    return a + b * cos(6.28318 * (c * t + d));
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float t = r * 3.0;
    vec3 col = iq_palette(t,
        vec3(0.5, 0.5, 0.5),
        vec3(0.5, 0.5, 0.5),
        vec3(1.0, 1.0, 1.0),
        vec3(0.0, 0.33, 0.67)
    );
    col *= smoothstep(1.0, 0.3, r);
    fragColor = vec4(col, 1.0);
}
