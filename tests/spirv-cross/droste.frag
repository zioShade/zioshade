#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Droste effect (recursive image within image)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Spiral zoom
    float zoom = log(r + 0.01) * 2.0;
    float rot = a + zoom;
    // Repeating pattern that gets smaller toward center
    float pattern = sin(rot * 6.0) * cos(zoom * 4.0);
    pattern = pattern * 0.5 + 0.5;
    vec3 col = vec3(pattern, pattern * 0.7, pattern * 0.4);
    col *= smoothstep(0.0, 0.1, r) * (1.0 - smoothstep(0.9, 1.0, r));
    fragColor = vec4(col, 1.0);
}
