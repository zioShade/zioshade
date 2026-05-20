#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // DNA double helix
    float t = uv.y * 10.0;
    float phase1 = sin(t) * 0.3;
    float phase2 = sin(t + 3.14159) * 0.3;
    // Two backbone strands
    float d1 = length(vec2(uv.x - phase1, 0.0));
    float d2 = length(vec2(uv.x - phase2, 0.0));
    float strand1 = smoothstep(0.03, 0.02, d1);
    float strand2 = smoothstep(0.03, 0.02, d2);
    // Base pair connections
    float cross_x = abs(phase1 - phase2);
    float cross_y = smoothstep(0.04, 0.02, abs(uv.x - (phase1 + phase2) * 0.5));
    float cross = cross_y * smoothstep(0.02, 0.01, abs(fract(t / 3.14159) - 0.5));
    vec3 col = vec3(0.05);
    col += vec3(0.3, 0.5, 1.0) * strand1;
    col += vec3(1.0, 0.3, 0.3) * strand2;
    col += vec3(0.5, 0.5, 0.5) * cross * 0.5;
    fragColor = vec4(col, 1.0);
}
