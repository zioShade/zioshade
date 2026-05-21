#version 310 es
precision highp float;
out vec4 fragColor;

// Test: vec2/vec3/vec4 mixed construction
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float s = sin(uv.x * 3.0);
    float c = cos(uv.y * 3.0);
    vec2 v2 = vec2(s, c);
    vec3 v3 = vec3(v2, s * c);
    vec4 v4 = vec4(v3, 1.0);
    // Extract and recombine
    vec2 ab = v4.xy;
    vec2 cd = v4.zw;
    float dot2 = dot(ab, cd);
    vec3 col = v3 * (dot2 + 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
