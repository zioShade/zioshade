#version 450
// Test: bilinear interpolation
vec3 bilinear(vec2 uv, vec3 tl, vec3 tr, vec3 bl, vec3 br) {
    vec3 top = mix(tl, tr, uv.x);
    vec3 bot = mix(bl, br, uv.x);
    return mix(top, bot, uv.y);
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = bilinear(uv, vec3(1,0,0), vec3(0,1,0), vec3(0,0,1), vec3(1,1,0));
    gl_FragColor = vec4(col, 1.0);
}
