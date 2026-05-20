#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Op art vibrating circles
    float r = length(uv);
    float rings = sin(r * 30.0 + sin(r * 5.0) * 3.0) * 0.5 + 0.5;
    rings = step(0.5, rings);
    vec3 col = mix(vec3(0.0), vec3(1.0), rings) * smoothstep(1.0, 0.9, r);
    fragColor = vec4(col, 1.0);
}
