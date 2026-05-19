#version 450

// Test: vec4 swizzle read/write combinations
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    vec4 a = vec4(0.0);
    a.xy = uv;
    a.zw = 1.0 - uv;

    float x = a.x;
    vec2 yz = a.yz;
    vec3 xyz = a.xyz;

    a.x = a.w;

    gl_FragColor = vec4(xyz * 0.5 + 0.5, a.w);
}
