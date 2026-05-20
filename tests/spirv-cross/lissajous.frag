#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Lissajous curve
    float t = gl_FragCoord.x * 0.02;
    float ax = 3.0;
    float ay = 2.0;
    float px = sin(ax * t + 1.0) * 0.7;
    float py = sin(ay * t) * 0.7;
    float d = length(uv - vec2(px, py));
    float curve = smoothstep(0.02, 0.01, d);
    vec3 col = vec3(0.05, 0.1, 0.15);
    col += vec3(0.2, 0.6, 1.0) * curve;
    // Glow
    col += vec3(0.1, 0.3, 0.5) * smoothstep(0.08, 0.02, d);
    fragColor = vec4(col, 1.0);
}
