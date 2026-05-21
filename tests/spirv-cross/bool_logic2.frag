#version 310 es
precision highp float;
out vec4 fragColor;

// Test: complex boolean logic with comparisons
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    bool inRing = r > 0.3 && r < 0.7;
    bool inSector = a > 0.0 && a < 1.5;
    bool inCenter = r < 0.15;
    bool active = (inRing && inSector) || inCenter;
    vec3 col = active ? vec3(0.7, 0.4, 0.2) : vec3(0.1, 0.1, 0.15);
    if (inRing && !inSector) {
        col = vec3(0.3, 0.3, 0.5);
    }
    fragColor = vec4(col, 1.0);
}
