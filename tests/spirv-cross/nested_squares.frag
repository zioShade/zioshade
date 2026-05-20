#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Nested squares (op art)
    float x = abs(uv.x);
    float y = abs(uv.y);
    float d = max(x, y);
    float rings = fract(d * 8.0);
    float bw = step(0.5, rings);
    // Rotation per ring
    float ring_id = floor(d * 8.0);
    float rot = ring_id * 0.15;
    vec2 rotated = vec2(cos(rot) * uv.x - sin(rot) * uv.y, sin(rot) * uv.x + cos(rot) * uv.y);
    float rd = max(abs(rotated.x), abs(rotated.y));
    float rrings = fract(rd * 8.0);
    float rbw = step(0.5, rrings);
    float combined = mod(bw + rbw, 2.0);
    vec3 col = vec3(combined) * smoothstep(1.0, 0.9, d);
    fragColor = vec4(col, 1.0);
}
