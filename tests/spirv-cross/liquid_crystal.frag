#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // O'Neill liquid crystal simulation
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Director field (nematic alignment)
    float director = a + sin(r * 10.0) * 0.5;
    float alignment = cos(director * 2.0) * 0.5 + 0.5;
    // Defect cores (disclinations)
    float defect1 = exp(-length(uv - vec2(0.2, 0.2)) * 20.0);
    float defect2 = exp(-length(uv - vec2(-0.3, -0.1)) * 20.0);
    vec3 col = vec3(alignment * 0.5, alignment * 0.7, alignment * 0.9);
    col += vec3(1.0, 0.3, 0.1) * (defect1 + defect2);
    col *= smoothstep(1.0, 0.8, r);
    fragColor = vec4(col, 1.0);
}
