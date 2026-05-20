#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float t = gl_FragCoord.x * 0.02;
    // Rotating triangle
    float angle = t;
    vec2 a = vec2(cos(angle), sin(angle)) * 0.5;
    vec2 b = vec2(cos(angle + 2.094), sin(angle + 2.094)) * 0.5;
    vec2 c = vec2(cos(angle + 4.189), sin(angle + 4.189)) * 0.5;
    
    float w1 = (b.y - c.y) * (uv.x - c.x) + (c.x - b.x) * (uv.y - c.y);
    float w2 = (c.y - a.y) * (uv.x - c.x) + (a.x - c.x) * (uv.y - c.y);
    float w3 = 1.0 - w1 - w2;
    
    float inside = step(0.0, w1) * step(0.0, w2) * step(0.0, w3);
    vec3 col = mix(vec3(0.1), vec3(0.8, 0.3, 0.5), inside);
    fragColor = vec4(col, 1.0);
}
