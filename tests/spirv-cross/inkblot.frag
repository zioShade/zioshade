#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Rorschach inkblot (mirror symmetry)
    uv.x = abs(uv.x); // mirror
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float blot = sin(a * 3.0) * cos(r * 5.0) * 0.5 + 0.5;
    blot *= smoothstep(1.0, 0.2, r);
    blot = step(0.45, blot);
    vec3 col = mix(vec3(0.95), vec3(0.05), blot);
    fragColor = vec4(col, 1.0);
}
