#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float linear = uv.x;
    float srgb = pow(linear, 1.0 / 2.2);
    gl_FragColor = vec4(vec3(srgb), 1.0);
}
