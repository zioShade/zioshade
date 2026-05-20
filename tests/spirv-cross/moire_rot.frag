#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Op art moire with rotation
    float angle = 0.1;
    float c = cos(angle);
    float s = sin(angle);
    vec2 rot_uv = vec2(c * uv.x - s * uv.y, s * uv.x + c * uv.y);
    float g1 = sin(uv.x * 40.0) * sin(uv.y * 40.0);
    float g2 = sin(rot_uv.x * 40.0) * sin(rot_uv.y * 40.0);
    float moire = (g1 + g2) * 0.5;
    float bw = step(0.0, moire);
    vec3 col = vec3(bw) * vec3(0.3, 0.4, 0.7);
    col *= smoothstep(1.0, 0.5, length(uv));
    fragColor = vec4(col, 1.0);
}
