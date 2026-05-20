#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Compound swizzle read-write
    vec4 v = vec4(sin(uv.x), cos(uv.y), sin(uv.x + uv.y), cos(uv.x - uv.y));
    v.xz = v.yw; // swizzle assignment
    vec3 col = v.xyz * 0.5 + 0.5;
    fragColor = vec4(col, 1.0);
}
