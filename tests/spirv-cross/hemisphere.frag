#version 450

// Test: face from dot product shading (hemisphere)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 normal = normalize(vec3(uv * 2.0 - 1.0, 0.5));
    vec3 up = vec3(0.0, 1.0, 0.0);

    float hemisphere = dot(normal, up) * 0.5 + 0.5;
    vec3 skyColor = mix(vec3(0.2, 0.3, 0.6), vec3(0.6, 0.7, 0.9), hemisphere);
    vec3 groundColor = vec3(0.3, 0.25, 0.2);

    vec3 col = hemisphere > 0.5 ? skyColor : groundColor;
    gl_FragColor = vec4(col, 1.0);
}
