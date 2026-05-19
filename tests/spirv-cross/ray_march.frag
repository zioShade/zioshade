#version 450

// Test: simple ray march (3 steps)
float scene(vec3 p) {
    return length(p) - 0.8;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    vec3 ro = vec3(0.0, 0.0, 3.0);
    vec3 rd = normalize(vec3(uv, -1.0));

    float t = 0.0;
    for (int i = 0; i < 8; i++) {
        float d = scene(ro + rd * t);
        t += d;
        if (d < 0.001) break;
    }

    vec3 col = t < 5.0 ? vec3(0.8, 0.4, 0.2) * (1.0 - t / 5.0) : vec3(0.1);
    gl_FragColor = vec4(col, 1.0);
}
