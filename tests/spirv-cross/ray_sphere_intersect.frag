#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    vec3 ro = vec3(0.0, 0.0, -2.0);
    vec3 rd = normalize(vec3(uv, 1.0));
    float b = dot(ro, rd);
    float c = dot(ro, ro) - 1.0;
    float disc = b * b - c;
    vec3 col = vec3(0.1);
    if (disc > 0.0) {
        float t = -b - sqrt(disc);
        if (t > 0.0) {
            vec3 p = ro + rd * t;
            vec3 n = normalize(p);
            float diff = max(dot(n, normalize(vec3(1.0, 1.0, -1.0))), 0.0);
            col = vec3(0.8, 0.3, 0.2) * (diff * 0.7 + 0.3);
        }
    }
    FragColor = vec4(col, 1.0);
}
