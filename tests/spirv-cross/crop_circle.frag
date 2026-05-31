#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Crop circle pattern
    vec2 center = vec2(5.0, 5.0);
    float r = length(uv - center);
    float a = atan(uv.y - 5.0, uv.x - 5.0);
    vec3 col = vec3(0.3, 0.5, 0.15); // wheat field
    // Flattened rings
    float ring1 = smoothstep(0.1, 0.08, abs(r - 2.0));
    float ring2 = smoothstep(0.1, 0.08, abs(r - 3.5));
    float ring3 = smoothstep(0.1, 0.08, abs(r - 1.0));
    vec3 flat_col = vec3(0.45, 0.55, 0.2);
    col = mix(col, flat_col, ring1);
    col = mix(col, flat_col, ring2);
    // Radial lines
    float spoke = smoothstep(0.03, 0.01, abs(sin(a * 6.0)));
    col = mix(col, flat_col, spoke * ring3);
    // Center circle
    float center_c = smoothstep(0.3, 0.25, r);
    col = mix(col, vec3(0.35, 0.5, 0.18), center_c);
    fragColor = vec4(col, 1.0);
}
