// Tests: swizzle write patterns
#version 450
uniform vec4 u_color;

void main() {
    vec4 c = u_color;
    c.x = c.y;
    c.z = c.w;
    c.y = c.x + 0.1;
    gl_FragColor = c;
}
