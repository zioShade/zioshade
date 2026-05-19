#version 450

// Test: multiple uniforms and global variables
uniform float u_time;
uniform vec2 u_resolution;
uniform vec2 u_mouse;

float globalScale = 1.0;

vec3 effect(vec2 uv) {
    float t = u_time * globalScale;
    vec2 p = uv * u_resolution / min(u_resolution.x, u_resolution.y);
    float d = length(p - u_mouse);
    return vec3(1.0 / (d + 0.1)) * 0.1;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = effect(uv);
    gl_FragColor = vec4(col, 1.0);
}
