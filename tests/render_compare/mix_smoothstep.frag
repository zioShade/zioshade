
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float t = smoothstep(0.2, 0.8, uv.x);
    vec3 red = vec3(1.0, 0.0, 0.0);
    vec3 blue = vec3(0.0, 0.0, 1.0);
    vec3 col = mix(red, blue, t);
    col = mix(col, vec3(0.0, 1.0, 0.0), smoothstep(0.3, 0.7, uv.y));
    FragColor = vec4(col, 1.0);
}
