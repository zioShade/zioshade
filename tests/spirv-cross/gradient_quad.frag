#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 tl = vec3(1.0, 0.0, 0.0);
    vec3 tr = vec3(0.0, 1.0, 0.0);
    vec3 bl = vec3(0.0, 0.0, 1.0);
    vec3 br = vec3(1.0, 1.0, 0.0);
    vec3 top = mix(tl, tr, uv.x);
    vec3 bot = mix(bl, br, uv.x);
    vec3 col = mix(bot, top, uv.y);
    FragColor = vec4(col, 1.0);
}
