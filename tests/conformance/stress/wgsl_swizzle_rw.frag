#version 450
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    // Vector swizzle read/write
    vec4 c = vec4(0.0);
    c.x = uv.x;
    c.y = uv.y;
    c.z = 0.5;
    c.w = 1.0;
    vec2 rg = c.xy;
    c.zw = vec2(0.3, 1.0);
    fragColor = c;
}
