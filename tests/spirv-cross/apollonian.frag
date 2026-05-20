#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Apollonian gasket (recursive circles)
    vec3 col = vec3(0.95);
    float r = length(uv);
    col = mix(col, vec3(0.1), step(r, 0.9));
    // Three touching circles
    float c1 = length(uv - vec2(0.0, 0.45));
    float c2 = length(uv - vec2(-0.39, -0.225));
    float c3 = length(uv - vec2(0.39, -0.225));
    col = mix(col, vec3(0.95), smoothstep(0.46, 0.44, c1));
    col = mix(col, vec3(0.95), smoothstep(0.46, 0.44, c2));
    col = mix(col, vec3(0.95), smoothstep(0.46, 0.44, c3));
    // Inner circles
    col = mix(col, vec3(0.1), smoothstep(0.2, 0.19, length(uv)));
    // Smaller circles in gaps
    col = mix(col, vec3(0.95), smoothstep(0.11, 0.1, length(uv - vec2(0.0, 0.3))));
    col = mix(col, vec3(0.95), smoothstep(0.11, 0.1, length(uv - vec2(-0.26, -0.15))));
    col = mix(col, vec3(0.95), smoothstep(0.11, 0.1, length(uv - vec2(0.26, -0.15))));
    fragColor = vec4(col, 1.0);
}
