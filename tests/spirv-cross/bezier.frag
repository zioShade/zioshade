#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Bezier curve visualization
    vec2 p0 = vec2(-0.8, -0.3);
    vec2 p1 = vec2(-0.2, 0.8);
    vec2 p2 = vec2(0.4, -0.6);
    vec2 p3 = vec2(0.8, 0.4);
    // Draw curve as series of points
    float min_d = 1.0;
    for (int i = 0; i <= 30; i++) {
        float t = float(i) / 30.0;
        float mt = 1.0 - t;
        vec2 pt = mt*mt*mt*p0 + 3.0*mt*mt*t*p1 + 3.0*mt*t*t*p2 + t*t*t*p3;
        float d = length(uv - pt);
        min_d = min(min_d, d);
    }
    float curve = smoothstep(0.01, 0.005, min_d);
    // Control polygon
    float cp1 = smoothstep(0.005, 0.002, length(uv - p0));
    float cp2 = smoothstep(0.005, 0.002, length(uv - p1));
    float cp3 = smoothstep(0.005, 0.002, length(uv - p2));
    float cp4 = smoothstep(0.005, 0.002, length(uv - p3));
    vec3 col = vec3(0.05);
    col += vec3(0.3, 0.6, 1.0) * curve;
    col += vec3(1.0, 0.3, 0.3) * (cp1 + cp2 + cp3 + cp4);
    fragColor = vec4(col, 1.0);
}
