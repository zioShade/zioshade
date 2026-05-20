#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Flower pattern with polar coordinates
    float petals = cos(a * 5.0) * 0.3 + 0.5;
    float shape = smoothstep(petals + 0.01, petals - 0.01, r);
    // Color based on angle
    vec3 col1 = vec3(0.9, 0.3, 0.4);
    vec3 col2 = vec3(0.4, 0.3, 0.9);
    float color_mix = sin(a * 3.0) * 0.5 + 0.5;
    vec3 col = mix(col1, col2, color_mix) * shape;
    col += vec3(0.1) * (1.0 - shape);
    fragColor = vec4(col, 1.0);
}
