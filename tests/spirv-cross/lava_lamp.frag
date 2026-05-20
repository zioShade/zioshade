#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Lava lamp effect
    float t = gl_FragCoord.x * 0.003;
    vec2 p1 = vec2(sin(t * 1.3) * 0.5 + 0.5, sin(t * 0.9) * 0.3 + 0.5);
    vec2 p2 = vec2(cos(t * 0.7 + 1.0) * 0.4 + 0.5, cos(t * 1.1 + 2.0) * 0.3 + 0.5);
    float d1 = length(uv - p1 * 15.0);
    float d2 = length(uv - p2 * 15.0);
    float blob1 = smoothstep(3.0, 2.0, d1);
    float blob2 = smoothstep(2.5, 1.5, d2);
    vec3 bg = vec3(0.1, 0.0, 0.1);
    vec3 c1 = vec3(0.8, 0.2, 0.0);
    vec3 c2 = vec3(0.9, 0.6, 0.0);
    vec3 col = bg;
    col = mix(col, c1, blob1);
    col = mix(col, c2, blob2);
    fragColor = vec4(col, 1.0);
}
