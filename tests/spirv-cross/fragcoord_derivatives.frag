#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // Complex gl_FragCoord usage with dFdx/dFdy
    vec2 fc = gl_FragCoord.xy;
    vec2 dx = dFdx(fc);
    vec2 dy = dFdy(fc);
    float w = dx.x * dx.x + dy.y * dy.y;

    // Conditional on FragCoord derivatives
    float val = 0.0;
    if (w > 0.1) {
        val = length(uv);
    } else {
        val = sqrt(uv.x * uv.x + uv.y * uv.y) * 0.5;
    }

    // Use gl_FragCoord in loop
    for (int i = 1; i <= 5; i++) {
        float fi = float(i);
        vec2 offset = fc / (300.0 * fi);
        val += sin(length(offset) * 10.0) * 0.1;
    }

    fragColor = vec4(clamp(vec3(val), 0.0, 1.0), 1.0);
}
