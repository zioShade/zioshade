// Tests: vec4 swizzle write patterns
#version 450
uniform float u_val;

void main() {
    vec4 c = vec4(0.0);
    c.x = u_val;
    c.y = u_val * 0.5;
    c.z = u_val * 0.25;
    c.w = 1.0;
    gl_FragColor = c;
}
