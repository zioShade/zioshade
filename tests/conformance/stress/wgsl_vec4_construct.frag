// Tests: vec4 construction from components and scalars
#version 450
uniform vec3 u_color;
uniform float u_alpha;

void main() {
    vec4 c1 = vec4(u_color, u_alpha);
    vec4 c2 = vec4(u_color.r, u_color.g, u_color.b, 1.0);
    vec4 c3 = vec4(0.5);
    vec4 result = (c1 + c2) * 0.5 + c3 * 0.1;
    gl_FragColor = result;
}
