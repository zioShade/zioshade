#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a; float b; float c;
    
    // 5-level nested if/else with different variable patterns
    if (r < 0.2) {
        a = 0.9;
        if (uv.x > 0.0) { b = 0.8; } else { b = 0.2; }
    } else if (r < 0.4) {
        a = 0.7;
        if (uv.y > 0.0) { b = 0.6; } else { b = 0.4; }
    } else if (r < 0.6) {
        a = 0.5;
        if (r < 0.5) { b = 0.3; } else { b = 0.7; }
    } else if (r < 0.8) {
        a = 0.3;
        if (uv.x > uv.y) { b = 0.5; } else { b = 0.1; }
    } else {
        a = 0.1;
        if (r < 0.9) { b = 0.9; } else { b = 0.0; }
    }
    c = a * b;
    vec3 col = vec3(a, b, c);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
