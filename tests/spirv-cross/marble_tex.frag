#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Marble texture
    float t = uv.x * 5.0;
    float n = sin(t + sin(t + sin(t) * 5.0) * 2.0);
    n = n * 0.5 + 0.5;
    vec3 white = vec3(0.95, 0.93, 0.9);
    vec3 gray = vec3(0.5, 0.48, 0.45);
    vec3 col = mix(white, gray, n);
    // Add veins
    float vein = abs(sin(uv.x * 40.0 + uv.y * 20.0));
    vein = smoothstep(0.02, 0.05, vein);
    col *= 0.8 + vein * 0.2;
    fragColor = vec4(col, 1.0);
}
