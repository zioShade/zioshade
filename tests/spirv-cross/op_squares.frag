#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Op art concentric squares
    float x = abs(uv.x);
    float y = abs(uv.y);
    float d = max(x, y);
    float rings = sin(d * 25.0) * 0.5 + 0.5;
    // Black and white only
    float bw = step(0.5, rings);
    vec3 col = vec3(bw) * smoothstep(1.0, 0.9, d);
    fragColor = vec4(col, 1.0);
}
