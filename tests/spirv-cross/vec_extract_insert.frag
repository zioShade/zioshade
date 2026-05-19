#version 450

// Test: extract/insert vector components
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec4 v = vec4(0.1, 0.2, 0.3, 0.4);

    float x = v.x;
    float y = v.y;
    vec2 xy = v.xy;
    vec3 xyz = v.xyz;

    v.z = uv.x;
    v.w = uv.y;

    gl_FragColor = vec4(v);
}
