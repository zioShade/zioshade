#version 310 es
precision highp float;
out vec4 fragColor;

// Test: vec4 extracted and used in arithmetic with type mixing
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec4 v = vec4(uv, 1.0 - length(uv), 1.0);
    float x = v.x * v.w;
    float y = v.y * v.z;
    vec2 result = vec2(x, y);
    float angle = atan(result.y, result.x);
    vec3 col = vec3(sin(angle) * 0.5 + 0.5, cos(angle) * 0.5 + 0.5, 0.5);
    fragColor = vec4(col, 1.0);
}
