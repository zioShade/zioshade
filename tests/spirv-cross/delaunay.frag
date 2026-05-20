#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Delaunay-like triangulation pattern
    float scale = 4.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Diagonal split based on cell hash
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    float d;
    if (h < 0.5) {
        d = abs(f.x - f.y);
    } else {
        d = abs(f.x + f.y - 1.0);
    }
    float edge = smoothstep(0.03, 0.01, d);
    float shade = h * 0.5 + 0.25;
    vec3 col = vec3(shade) + vec3(0.4, 0.3, 0.2) * edge;
    fragColor = vec4(col, 1.0);
}
