#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Morphing shape (circle to square)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Interpolate between circle and rounded square
    float morph = gl_FragCoord.x / 300.0;
    float circle_d = r - 0.6;
    float box_d = max(abs(uv.x), abs(uv.y)) - 0.5;
    float d = mix(circle_d, box_d, morph);
    float shape = smoothstep(0.02, -0.02, d);
    vec3 col = vec3(0.3, 0.5, 0.8) * shape;
    fragColor = vec4(col, 1.0);
}
