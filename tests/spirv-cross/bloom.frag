#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float d = length(uv - 0.5);
    float bloom = exp(-d * 4.0) + exp(-d * 8.0) * 0.5;
    vec3 col = vec3(1.0, 0.9, 0.7) * bloom;
    gl_FragColor = vec4(col, 1.0);
}
