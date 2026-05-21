#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec4 v = vec4(0.0);
    v.xz = uv.xyx.yz;  // swizzle write with swizzle source
    v.yw = vec2(sin(uv.x), cos(uv.y));
    vec3 col = v.rgb * 0.5 + 0.5;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
