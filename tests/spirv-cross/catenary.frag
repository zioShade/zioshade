#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Catenary / hanging chain curve
    float chain1 = cosh(uv.x * 2.0) * 0.15 - 0.3;
    float chain2 = cosh((uv.x - 0.3) * 1.5) * 0.12 - 0.1;
    float d1 = abs(uv.y - chain1);
    float d2 = abs(uv.y - chain2);
    float line1 = smoothstep(0.02, 0.01, d1);
    float line2 = smoothstep(0.02, 0.01, d2);
    vec3 col = vec3(0.05);
    col += vec3(0.8, 0.7, 0.3) * line1;
    col += vec3(0.3, 0.7, 0.8) * line2;
    fragColor = vec4(col, 1.0);
}
