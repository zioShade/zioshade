#version 450

// Test: vec4 to float conversions via component access
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    vec4 a = vec4(uv, 1.0 - uv);
    float x = a.x;
    float y = a.y;
    float z = a.z;
    float w = a.w;

    vec2 b = a.xy;
    vec2 c = a.zw;

    vec3 d = vec3(b, c.x);

    gl_FragColor = vec4(d, w);
}
