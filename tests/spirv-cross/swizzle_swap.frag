#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec4 a = vec4(1.0, 2.0, 3.0, 4.0);
    vec4 b = vec4(uv.x, uv.y, sin(uv.x), cos(uv.y));
    a.wy = b.xz;
    b.xz = a.yw;
    a.x = b.y + b.w;
    vec3 col = (a.xyz + b.xyz) * 0.1;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
