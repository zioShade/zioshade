#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Nebula / space cloud
    float r = length(uv);
    float n1 = sin(uv.x * 5.0 + uv.y * 3.0) * cos(uv.x * 3.0 - uv.y * 5.0);
    float n2 = sin(uv.x * 8.0 - uv.y * 6.0) * cos(uv.x * 4.0 + uv.y * 7.0);
    float density = (n1 + n2 * 0.5) * 0.3 + 0.3;
    density *= exp(-r * 1.5);
    // Color variation
    vec3 red = vec3(0.8, 0.2, 0.3);
    vec3 blue = vec3(0.2, 0.3, 0.8);
    vec3 purple = vec3(0.5, 0.1, 0.6);
    vec3 nebula = mix(red, blue, sin(uv.x * 2.0) * 0.5 + 0.5);
    nebula = mix(nebula, purple, sin(uv.y * 3.0) * 0.5 + 0.5);
    // Stars
    float star = fract(sin(dot(floor(uv * 100.0), vec2(127.1, 311.7))) * 43758.5);
    vec3 col = nebula * density + vec3(step(0.98, star)) * 0.5;
    fragColor = vec4(col, 1.0);
}
