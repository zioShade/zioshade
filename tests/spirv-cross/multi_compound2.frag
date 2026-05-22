#version 310 es
precision highp float;
out vec4 fragColor;

// Multiple compound assignments across branches with different types
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float f = 1.0;
    vec2 v2 = vec2(0.0);
    vec3 v3 = vec3(0.0);
    vec4 v4 = vec4(0.0);

    if (uv.x > 0.25) { f += 0.3; v2 += vec2(0.1); v3 += vec3(0.2); v4 += vec4(0.1); }
    if (uv.x > 0.50) { f *= 1.5; v2 *= vec2(0.8); v3 *= vec3(0.9); v4 *= vec4(1.1); }
    if (uv.x > 0.75) { f -= 0.2; v2 -= vec2(0.05); v3 -= vec3(0.1); v4 -= vec4(0.05); }

    // Use all accumulated values
    float val = f + v2.x + v2.y + v3.x + v3.y + v3.z + v4.x + v4.y + v4.z + v4.w;
    val *= 0.1;

    vec3 col = vec3(val);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
