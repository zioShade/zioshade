#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    
    // Variables assigned in branches then modified after
    float a, b;
    if (r < 0.3) {
        a = sin(uv.x * 10.0);
        b = cos(uv.y * 10.0);
    } else if (r < 0.6) {
        a = cos(uv.x * 8.0);
        b = sin(uv.y * 8.0);
    } else {
        a = 0.0;
        b = 0.0;
    }
    a += 0.5;
    b += 0.5;
    vec3 col = vec3(a * 0.5 + 0.3, b * 0.5 + 0.2, (a + b) * 0.25);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
