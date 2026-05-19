#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float pinch = r > 0.001 ? pow(r, 0.5) / r : 1.0;
    vec2 distorted = p * pinch * 0.5 + 0.5;
    vec3 col = vec3(distorted, 0.5);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
