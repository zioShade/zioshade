#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float pattern = sin(r * 15.0 - a * 3.0) * 0.5 + 0.5;
    vec3 col = vec3(pattern, pattern * 0.7, pattern * 0.3) / (r + 0.1) * 0.3;
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
