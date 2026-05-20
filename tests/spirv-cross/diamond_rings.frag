#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Concentric diamond pattern
    float d = abs(uv.x) + abs(uv.y); // L1 distance = diamond
    float rings = sin(d * 20.0) * 0.5 + 0.5;
    float fade = exp(-d * 2.0);
    vec3 col = vec3(rings) * fade;
    // Add axis highlights
    float axis_x = smoothstep(0.02, 0.0, abs(uv.y));
    float axis_y = smoothstep(0.02, 0.0, abs(uv.x));
    col += vec3(0.5, 0.2, 0.2) * axis_x + vec3(0.2, 0.2, 0.5) * axis_y;
    fragColor = vec4(col, 1.0);
}
