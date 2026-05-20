#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.02;
    // Metal brushed effect
    float grain = fract(sin(dot(floor(uv * 100.0), vec2(12.9898, 78.233))) * 43758.5453);
    float streak = sin(uv.y * 200.0) * 0.5 + 0.5;
    float combined = grain * 0.3 + streak * 0.7;
    vec3 metal = vec3(0.7, 0.72, 0.75) * combined;
    // Highlight
    float hl = smoothstep(0.8, 1.0, sin(uv.x * 3.14159) * sin(uv.y * 0.5));
    metal += vec3(0.2) * hl;
    fragColor = vec4(metal, 1.0);
}
