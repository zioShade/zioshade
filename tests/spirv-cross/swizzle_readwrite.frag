#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec4 c = vec4(0.0);
    // Read and write swizzles
    c.xy = vec2(0.5, 0.3);
    c.zw = c.xy * 2.0;
    vec2 temp = c.xz;
    c.yw = temp;
    c.x = c.z + c.w;
    c.y *= 0.5;
    fragColor = c;
}
