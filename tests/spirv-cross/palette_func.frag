#version 450

// Test: conditional return from multiple branches
vec3 palette(float t) {
    if (t < 0.25) return vec3(1.0, t * 4.0, 0.0);
    else if (t < 0.5) return vec3(1.0 - (t - 0.25) * 4.0, 1.0, 0.0);
    else if (t < 0.75) return vec3(0.0, 1.0, (t - 0.5) * 4.0);
    else return vec3(0.0, 1.0 - (t - 0.75) * 4.0, 1.0);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = palette(uv.x);
    col *= smoothstep(0.0, 0.5, uv.y);
    gl_FragColor = vec4(col, 1.0);
}
