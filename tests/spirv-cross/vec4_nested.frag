#version 450

// Test: vec4 construction from nested expressions
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float a = sin(uv.x * 3.14);
    float b = cos(uv.y * 3.14);
    vec2 c = vec2(a, b);
    float d = length(c);

    vec4 result = vec4(c, d, 1.0 - d);
    gl_FragColor = result;
}
