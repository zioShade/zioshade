#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Flame / fire effect
    float heat = 0.0;
    // Base shape (narrow at top, wide at bottom)
    float width = 0.3 + (1.0 - uv.y) * 0.3;
    float in_flame = step(abs(uv.x), width) * step(0.0, uv.y) * step(uv.y, 1.0);
    // Turbulence
    float turb = sin(uv.y * 15.0 + sin(uv.x * 8.0) * 3.0) * 0.1;
    float turb2 = cos(uv.y * 20.0 + sin(uv.x * 12.0 + 1.0) * 2.0) * 0.05;
    heat = (0.5 + turb + turb2) * in_flame;
    // Height-based color (white -> yellow -> orange -> red)
    float h = uv.y;
    vec3 col = vec3(0.0);
    if (h > 0.7) col = mix(vec3(1.0, 0.8, 0.2), vec3(1.0, 1.0, 0.9), (h - 0.7) / 0.3);
    else if (h > 0.3) col = mix(vec3(0.9, 0.3, 0.0), vec3(1.0, 0.8, 0.2), (h - 0.3) / 0.4);
    else col = mix(vec3(0.3, 0.0, 0.0), vec3(0.9, 0.3, 0.0), h / 0.3);
    col *= heat;
    fragColor = vec4(col, 1.0);
}
