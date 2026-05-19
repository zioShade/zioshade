#version 450

// Test: complex nested expressions in function args
vec3 add3(vec3 a, vec3 b) { return a + b; }
vec3 scale(vec3 v, float s) { return v * s; }
float sum(vec3 v) { return v.x + v.y + v.z; }

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 a = vec3(uv, 0.5);
    vec3 b = vec3(1.0 - uv, 0.3);
    // Nested function calls in expressions
    vec3 c = add3(scale(a, 2.0), scale(b, 0.5));
    float s = sum(c);
    gl_FragColor = vec4(c / max(s, 0.01), 1.0);
}
