#version 450

// Test: face-based conditional with multiple vec3 returns
vec3 skyColor(vec2 uv) {
    float t = uv.y;
    vec3 bottom = vec3(0.6, 0.8, 1.0);
    vec3 top = vec3(0.1, 0.2, 0.5);
    return mix(bottom, top, t);
}

vec3 groundColor(vec2 uv) {
    float t = uv.y;
    vec3 near = vec3(0.2, 0.5, 0.1);
    vec3 far = vec3(0.4, 0.3, 0.2);
    return mix(near, far, t);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = uv.y > 0.5 ? skyColor(uv) : groundColor(uv);
    gl_FragColor = vec4(col, 1.0);
}
