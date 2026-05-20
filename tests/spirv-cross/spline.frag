#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Kochanek-Bartels spline interpolation
    float t = uv.x * 0.5 + 0.5;
    float t2 = t * t;
    float t3 = t2 * t;
    // Hermite basis functions
    float h1 = 2.0*t3 - 3.0*t2 + 1.0;
    float h2 = -2.0*t3 + 3.0*t2;
    float h3 = t3 - 2.0*t2 + t;
    float h4 = t3 - t2;
    // Control points
    float p0 = -0.5, p1 = 0.8, m0 = 1.0, m1 = -0.5;
    float val = h1*p0 + h2*p1 + h3*m0 + h4*m1;
    float d = abs(uv.y - val);
    float line = smoothstep(0.02, 0.005, d);
    vec3 col = vec3(0.05) + vec3(0.4, 0.8, 0.4) * line;
    fragColor = vec4(col, 1.0);
}
