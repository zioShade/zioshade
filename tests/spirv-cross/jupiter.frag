#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Jupiter-like planet with bands
    float r = length(uv);
    // Latitude-based bands
    float lat = uv.y;
    float band1 = smoothstep(0.02, 0.0, abs(lat - 0.1));
    float band2 = smoothstep(0.04, 0.0, abs(lat - 0.3));
    float band3 = smoothstep(0.03, 0.0, abs(lat + 0.2));
    float band4 = smoothstep(0.05, 0.0, abs(lat + 0.5));
    // Base color
    vec3 base = vec3(0.8, 0.65, 0.4);
    vec3 col = base;
    col = mix(col, vec3(0.6, 0.4, 0.2), band1 + band3);
    col = mix(col, vec3(0.9, 0.75, 0.5), band2 + band4);
    // Great red spot
    float spot_d = length((uv - vec2(0.2, -0.15)) * vec2(1.5, 2.0));
    col = mix(col, vec3(0.8, 0.3, 0.2), smoothstep(0.15, 0.1, spot_d));
    // Sphere shading
    col *= sqrt(max(1.0 - r * r, 0.0));
    col *= step(r, 0.9);
    fragColor = vec4(col, 1.0);
}
