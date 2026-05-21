#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Multi-branch with compound assignment in each branch
    float score = 0.0;
    float d = length(uv - vec2(5.0, 5.0));
    
    if (d < 1.0) {
        score += 3.0;
        score *= 1.5;
    } else if (d < 2.0) {
        score += 2.0;
        score += sin(d * 5.0) * 0.5;
    } else if (d < 3.0) {
        score += 1.0;
        score -= d * 0.1;
    } else {
        score = 0.1;
    }
    
    vec3 col = vec3(score * 0.2, score * 0.3, score * 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
