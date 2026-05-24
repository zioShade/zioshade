// Tests: complex swizzle patterns
#version 450
uniform vec4 u_color;

void main() {
    vec4 c = u_color;
    c.xw = c.yz;   // swizzle write
    vec3 rgb = c.xyz;
    vec2 rg = c.xy;
    float r = c.x;
    gl_FragColor = vec4(rgb + vec3(r), 1.0);
}
