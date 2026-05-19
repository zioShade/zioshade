#version 450

// Test: bvec construction and usage
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    bvec2 b1 = bvec2(uv.x > 0.5, uv.y > 0.5);
    bvec3 b2 = bvec3(true, false, uv.x > 0.3);
    bvec4 b3 = bvec4(b1, b2.xy);

    float r = any(b1) ? 1.0 : 0.0;
    float g = all(b1) ? 1.0 : 0.5;
    float bl = float(b2.z);

    gl_FragColor = vec4(r, g, bl, 1.0);
}
