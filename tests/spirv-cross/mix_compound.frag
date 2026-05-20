#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float t = gl_FragCoord.x * 0.005;
    vec3 warm = vec3(1.0, 0.5, 0.2);
    vec3 cool = vec3(0.2, 0.5, 1.0);
    vec3 hot = vec3(1.0, 0.8, 0.1);
    // Layered mix
    vec3 base = mix(cool, warm, t);
    vec3 highlight = mix(base, hot, smoothstep(0.6, 0.9, t));
    vec3 final_col = mix(highlight, vec3(0.1), smoothstep(0.95, 1.0, t));
    fragColor = vec4(final_col, 1.0);
}
