#version 450

// Test vector swizzle write patterns
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    vec4 c = vec4(0.0);
    c.xy = uv;
    c.z = 0.5;
    c.w = 1.0;

    vec3 v = vec3(0.0);
    v.xz = uv;

    gl_FragColor = vec4(c.x, c.y, v.x + v.z, c.w);
}
