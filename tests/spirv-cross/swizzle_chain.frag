#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Complex swizzle read-write chains
    vec4 a = vec4(1.0, 2.0, 3.0, 4.0);
    a.xy = a.zw;
    a.zw = a.xy * 0.5;
    vec4 b = vec4(uv.x, uv.y, sin(uv.x), cos(uv.y));
    b.xz = b.yw;
    b.yw = b.xz * 2.0;
    vec3 col = (a.xyz + b.xyz) * 0.05;
    col = clamp(col, 0.0, 1.0);
    fragColor = vec4(col, 1.0);
}
