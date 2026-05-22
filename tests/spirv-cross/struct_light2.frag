#version 310 es
precision highp float;
out vec4 fragColor;

// Struct with function that returns struct - simplified version
struct Light {
    vec3 color;
    float intensity;
};

Light makeLight(vec3 c, float i) {
    Light l;
    l.color = c;
    l.intensity = i;
    return l;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    Light l1 = makeLight(vec3(1.0, 0.5, 0.0), 2.0);
    Light l2 = makeLight(vec3(0.0, 0.5, 1.0), 1.5);

    vec3 col = l1.color * l1.intensity * smoothstep(0.3, 0.0, length(uv - vec2(0.3)));
    col += l2.color * l2.intensity * smoothstep(0.3, 0.0, length(uv - vec2(0.7)));

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
