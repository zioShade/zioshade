#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Regular polygon
    float n = 6.0; // hexagon
    float a = atan(uv.y, uv.x);
    float r = length(uv);
    float side = 3.14159 / n;
    float d = cos(floor(a / side + 0.5) * side - a) * r;
    float hex = 1.0 - smoothstep(0.48, 0.5, d);
    vec3 col = hex * vec3(0.3, 0.6, 0.9);
    fragColor = vec4(col, 1.0);
}
