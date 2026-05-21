#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float closest = 10.0;
    vec3 closestCol = vec3(0.0);
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        vec2 center = vec2(cos(fi * 1.256) * 0.5, sin(fi * 1.256) * 0.5);
        float d = length(uv - center);
        if (d < closest) {
            closest = d;
            closestCol = vec3(
                0.5 + 0.5 * sin(fi * 2.0),
                0.5 + 0.5 * sin(fi * 2.0 + 2.0),
                0.5 + 0.5 * sin(fi * 2.0 + 4.0)
            );
        }
    }
    float alpha = smoothstep(0.3, 0.0, closest);
    vec3 col = mix(vec3(0.05), closestCol, alpha);
    fragColor = vec4(col, 1.0);
}
