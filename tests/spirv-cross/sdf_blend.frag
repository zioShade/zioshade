#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // SDF smooth union in branches
    float d1 = length(uv - vec2(-0.3, 0.0)) - 0.4;
    float d2 = length(uv - vec2(0.3, 0.0)) - 0.35;
    
    vec3 col = vec3(0.05);
    if (d1 < 0.0 && d2 < 0.0) {
        float blend = smoothstep(-0.1, 0.0, d1 - d2);
        col = mix(vec3(0.8, 0.2, 0.2), vec3(0.2, 0.2, 0.8), blend);
    } else if (d1 < 0.0) {
        float shade = smoothstep(0.0, -0.4, d1);
        col = vec3(0.8, 0.2, 0.2) * shade;
    } else if (d2 < 0.0) {
        float shade = smoothstep(0.0, -0.35, d2);
        col = vec3(0.2, 0.2, 0.8) * shade;
    }
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
