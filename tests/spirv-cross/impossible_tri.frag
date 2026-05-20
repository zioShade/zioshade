#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Penrose-style impossible triangle
    float scale = 2.5;
    vec2 p = uv * scale;
    float d = length(p);
    // Three beams at 120 degrees
    float beam_width = 0.15;
    float a1 = atan(p.y - 0.3, p.x + 0.5);
    float a2 = atan(p.y - 0.3, p.x - 0.5);
    float a3 = atan(p.y + 0.5, p.x);
    float b1 = abs(p.y - 0.3 - (p.x + 0.5) * 0.577) / 1.15;
    float b2 = abs(p.y - 0.3 + (p.x - 0.5) * 0.577) / 1.15;
    float b3 = abs(p.y + 0.5) / 1.15;
    float min_beam = min(b1, min(b2, b3));
    float beam = smoothstep(beam_width, beam_width - 0.02, min_beam) * step(0.3, d);
    vec3 col = vec3(beam) * vec3(0.4, 0.6, 0.8);
    fragColor = vec4(col, 1.0);
}
