#version 450

// Test multiple return statements (early returns from different paths)
float classify(float x) {
    if (x < 0.25) return 0.1;
    if (x < 0.5) return 0.3;
    if (x < 0.75) return 0.6;
    return 1.0;
}

vec3 getColor(float v) {
    if (v < 0.3) return vec3(1.0, 0.0, 0.0);
    if (v < 0.6) return vec3(0.0, 1.0, 0.0);
    return vec3(0.0, 0.0, 1.0);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float c = classify(uv.x);
    vec3 col = getColor(uv.y);
    gl_FragColor = vec4(col * c, 1.0);
}
