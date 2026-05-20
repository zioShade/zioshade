#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Color temperature scale (cool to warm)
    float t = uv.x * 0.5 + 0.5;
    // Kelvin approximation: 1000K (red) to 10000K (blue-white)
    vec3 col;
    if (t < 0.2) {
        col = vec3(1.0, 0.3, 0.0);
    } else if (t < 0.4) {
        col = mix(vec3(1.0, 0.3, 0.0), vec3(1.0, 0.8, 0.4), (t - 0.2) / 0.2);
    } else if (t < 0.6) {
        col = mix(vec3(1.0, 0.8, 0.4), vec3(1.0, 1.0, 1.0), (t - 0.4) / 0.2);
    } else if (t < 0.8) {
        col = mix(vec3(1.0, 1.0, 1.0), vec3(0.7, 0.8, 1.0), (t - 0.6) / 0.2);
    } else {
        col = mix(vec3(0.7, 0.8, 1.0), vec3(0.4, 0.5, 1.0), (t - 0.8) / 0.2);
    }
    col *= 0.5 + 0.5 * smoothstep(0.3, 0.7, t);
    fragColor = vec4(col, 1.0);
}
