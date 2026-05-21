#version 310 es
precision highp float;
out vec4 fragColor;

// Test: vec4 swizzle read from function result
vec3 rotate2d(vec2 uv, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return vec3(c * uv.x - s * uv.y, s * uv.x + c * uv.y, angle);
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec3 result = rotate2d(uv, uv.x * 2.0);
    vec2 rotated = result.xy;
    float angle = result.z;
    vec3 col = vec3(abs(rotated.x), abs(rotated.y), 0.3 + 0.2 * sin(angle));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
