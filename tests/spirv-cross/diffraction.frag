#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Diffraction grating
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Multiple slit diffraction pattern
    float slits = 5.0;
    float slit_width = 0.1;
    float single = sin(slit_width * r * 80.0) / (slit_width * r * 80.0 + 0.001);
    float multi = sin(slits * a) / (sin(a) * slits + 0.001);
    float diffraction = abs(single * multi);
    // Prismatic colors based on angle
    vec3 col = vec3(
        diffraction * (0.5 + 0.5 * sin(a + 0.0)),
        diffraction * (0.5 + 0.5 * sin(a + 2.09)),
        diffraction * (0.5 + 0.5 * sin(a + 4.18))
    );
    col *= smoothstep(1.2, 0.3, r);
    fragColor = vec4(col, 1.0);
}
