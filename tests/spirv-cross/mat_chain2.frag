#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float a1 = uv.x * 1.5;
    float a2 = uv.y * 1.2;
    float s = 0.5 + 0.5 * sin(uv.x * 3.0);
    mat2 rot1 = mat2(cos(a1), -sin(a1), sin(a1), cos(a1));
    mat2 scale = mat2(s, 0.0, 0.0, s);
    mat2 rot2 = mat2(cos(a2), -sin(a2), sin(a2), cos(a2));
    vec2 transformed = rot2 * scale * rot1 * uv;
    float val = length(transformed);
    vec3 col = vec3(val * 0.3, val * 0.5, val * 0.8);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
