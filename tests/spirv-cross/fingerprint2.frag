#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Fingerprints / concentric distorted rings
    float cx = 5.0 + sin(uv.y * 0.5) * 0.5;
    float r = abs(uv.x - cx);
    float rings = sin(r * 30.0 + sin(uv.y * 2.0) * 3.0) * 0.5 + 0.5;
    vec3 col = vec3(0.85, 0.75, 0.6) * (0.6 + 0.4 * rings);
    fragColor = vec4(col, 1.0);
}
