#version 450

// Test: vec3 swizzle and component access patterns
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    vec3 v = vec3(uv, uv.x * uv.y);

    // Various swizzle patterns
    float a = v.x;
    float b = v.y;
    vec2 c = v.xy;
    vec2 d = v.yz;
    vec2 e = v.xz;
    vec3 f = v.yzx;
    vec3 g = v.zxy;

    gl_FragColor = vec4(c, d) * 0.5 + vec4(f.x, f.y, f.z, 0.5);
}
