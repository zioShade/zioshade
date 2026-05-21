#version 310 es
precision highp float;
out vec4 fragColor;

// Test: variable initialized in branch then used after
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float scale;
    vec3 tint;
    if (r < 0.4) {
        scale = 2.0;
        tint = vec3(1.0, 0.8, 0.6);
    } else {
        scale = 0.5;
        tint = vec3(0.4, 0.6, 1.0);
    }
    vec3 col = tint * scale * smoothstep(1.0, 0.0, r);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
