#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 lightPos = vec2(0.5, 0.8);
    float d = distance(uv, lightPos);
    float spot = exp(-d * d * 10.0);
    vec3 col = vec3(0.8, 0.7, 0.5) * spot + vec3(0.05, 0.05, 0.1);
    gl_FragColor = vec4(col, 1.0);
}
