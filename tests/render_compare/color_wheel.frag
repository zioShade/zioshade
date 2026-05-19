#version 430
layout(location = 0) out vec4 FragColor;

// Test: HSV color wheel
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 2.0 - 1.0;
    float angle = atan(p.y, p.x) / 6.2832 + 0.5;
    float dist = length(p);

    vec3 col = vec3(angle, 1.0, 1.0 - dist);
    // HSV to RGB inline
    vec3 rgb = clamp(abs(mod(angle * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
    rgb = mix(vec3(1.0), rgb, col.y);
    rgb *= col.z;

    FragColor = vec4(rgb, 1.0);
}
