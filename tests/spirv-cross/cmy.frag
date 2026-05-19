#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 rgb = vec3(uv, 0.5);
    vec3 cmy = 1.0 - rgb;
    gl_FragColor = vec4(cmy, 1.0);
}
