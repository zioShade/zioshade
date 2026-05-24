// Tests: depth gl_FragDepth output
#version 450
uniform float u_depth;

void main() {
    gl_FragDepth = u_depth;
    gl_FragColor = vec4(u_depth, 0.0, 0.0, 1.0);
}
