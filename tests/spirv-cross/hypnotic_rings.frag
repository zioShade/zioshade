#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Concentric rings with rotation
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float rings = sin(r * 20.0 - a * 3.0) * 0.5 + 0.5;
    // Spiral overlay
    float spiral = sin(r * 30.0 - a * 5.0 + 1.57) * 0.5 + 0.5;
    vec3 col = mix(vec3(0.9, 0.3, 0.2), vec3(0.1, 0.4, 0.8), rings);
    col = mix(col, vec3(1.0), spiral * 0.3);
    col *= smoothstep(1.2, 0.3, r);
    fragColor = vec4(col, 1.0);
}
