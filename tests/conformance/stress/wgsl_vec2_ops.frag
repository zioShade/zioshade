// Tests: multiple vec2 operations (add, sub, scale, length)
#version 450
uniform vec2 u_a;
uniform vec2 u_b;
uniform float u_scale;

void main() {
    vec2 sum = u_a + u_b;
    vec2 diff = u_a - u_b;
    vec2 scaled = sum * u_scale;
    float len = length(diff);
    float r = scaled.x / (len + 0.001);
    float g = scaled.y / (len + 0.001);
    gl_FragColor = vec4(r, g, len, 1.0);
}
