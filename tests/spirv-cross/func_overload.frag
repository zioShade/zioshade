#version 450

// Test function overloading (same name, different parameter types)
float process(float x) { return x * 2.0; }
vec2 process(vec2 v) { return v * 2.0; }
vec3 process(vec3 v) { return v * 2.0; }

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float a = process(uv.x);
    vec2 b = process(uv);
    vec3 c = process(vec3(uv, 0.5));
    gl_FragColor = vec4(a, b, c.z);
}
