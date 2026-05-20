#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Cel shading with posterization
    float val = sin(uv.x * 3.0) * cos(uv.y * 4.0) * 0.5 + 0.5;
    float levels = 4.0;
    float posterized = floor(val * levels + 0.5) / levels;
    // Edge detection via gradient
    float dx = dFdx(val) * 50.0;
    float dy = dFdy(val) * 50.0;
    float edge = 1.0 - smoothstep(0.1, 0.3, length(vec2(dx, dy)));
    vec3 col = vec3(posterized) * edge;
    fragColor = vec4(col, 1.0);
}
