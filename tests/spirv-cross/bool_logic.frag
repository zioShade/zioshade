#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Complex boolean logic
    float x = step(0.0, uv.x);
    float y = step(0.0, uv.y);
    // AND
    float both = x * y;
    // OR
    float either = min(x + y, 1.0);
    // XOR
    float exclusive = abs(x - y);
    // Color each quadrant differently
    vec3 col = vec3(0.05);
    col += vec3(1.0, 0.3, 0.2) * both * 0.5;      // NE: warm
    col += vec3(0.2, 0.3, 1.0) * exclusive * 0.5;   // NW/SE: cool
    col += vec3(0.8, 0.8, 0.2) * (1.0 - either) * 0.3; // SW: golden
    fragColor = vec4(col, 1.0);
}
