#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // gl_FrontFacing builtin
    float facing = gl_FrontFacing ? 1.0 : 0.0;
    vec3 col = mix(vec3(0.2, 0.4, 0.8), vec3(0.8, 0.4, 0.2), facing);
    fragColor = vec4(col * uv.x, 1.0);
}
