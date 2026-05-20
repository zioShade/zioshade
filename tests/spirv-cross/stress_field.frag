#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Tension field / stress visualization
    float sxx = sin(uv.x * 3.0) * cos(uv.y * 2.0);
    float syy = cos(uv.x * 2.0) * sin(uv.y * 3.0);
    float sxy = sin(uv.x * 4.0 + uv.y * 3.0) * 0.5;
    // Principal stresses
    float p = (sxx + syy) * 0.5;
    float q = sqrt((sxx - syy) * (sxx - syy) * 0.25 + sxy * sxy);
    float s1 = p + q;
    float s2 = p - q;
    // Color by von Mises stress
    float vm = sqrt(s1 * s1 - s1 * s2 + s2 * s2);
    vec3 col = mix(vec3(0.0, 0.0, 0.8), vec3(0.8, 0.0, 0.0), vm * 2.0);
    col = mix(col, vec3(1.0), smoothstep(0.8, 1.0, vm * 2.0));
    fragColor = vec4(col, 1.0);
}
