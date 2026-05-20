#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Op art moire v2 (concentric circles vs grid)
    float r = length(uv);
    float circles = sin(r * 40.0) * 0.5 + 0.5;
    float grid = sin(uv.x * 40.0) * sin(uv.y * 40.0) * 0.5 + 0.5;
    float moire = circles * grid;
    vec3 col = vec3(moire) * vec3(0.2, 0.3, 0.6);
    col *= smoothstep(1.0, 0.5, r);
    fragColor = vec4(col, 1.0);
}
