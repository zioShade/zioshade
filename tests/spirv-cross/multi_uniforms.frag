#version 450

// Test: multiple uniform variables
uniform float u_scale;
uniform vec3 u_color;
uniform vec2 u_offset;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = (uv + u_offset) * u_scale;
    vec3 col = u_color * smoothstep(0.0, 1.0, length(p));
    gl_FragColor = vec4(col, 1.0);
}
