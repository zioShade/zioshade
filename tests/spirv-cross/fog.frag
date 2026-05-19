#version 450

// Test: face distance-based fog
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 objColor = vec3(0.8, 0.4, 0.2);
    vec3 fogColor = vec3(0.5, 0.6, 0.7);

    float depth = length(uv - 0.5) * 2.0;
    float fogFactor = 1.0 - exp(-depth * 2.0);

    vec3 col = mix(objColor, fogColor, fogFactor);
    gl_FragColor = vec4(col, 1.0);
}
