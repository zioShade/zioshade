#version 450

// Test: vector swizzle as lvalue (write target)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    vec4 c = vec4(0.0, 0.0, 0.0, 1.0);
    c.x = uv.x;
    c.y = uv.y;
    c.z = (uv.x + uv.y) * 0.5;

    vec3 v = vec3(0.0);
    v.xy = uv * 2.0;

    gl_FragColor = vec4(c.x + v.x * 0.1, c.y, c.z, c.w);
}
