#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Op art checkerboard warp
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Warped coordinates
    vec2 warp = vec2(uv.x / (r + 0.1), uv.y / (r + 0.1));
    float checker = sin(uv.x * 20.0 + sin(r * 10.0) * 3.0) * sin(uv.y * 20.0 + cos(r * 10.0) * 3.0);
    checker = step(0.0, checker);
    vec3 col = mix(vec3(0.0), vec3(1.0), checker) * smoothstep(1.2, 0.3, r);
    fragColor = vec4(col, 1.0);
}
