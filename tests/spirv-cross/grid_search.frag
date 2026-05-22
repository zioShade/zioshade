#version 310 es
precision highp float;
out vec4 fragColor;

// Complex nested loop with break + continue + multiple tracked variables
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float bestDist = 10.0;
    vec2 bestPos = vec2(0.0);
    int bestIdx = 0;
    float totalWeight = 0.0;

    for (int j = 0; j < 5; j++) {
        for (int i = 0; i < 5; i++) {
            vec2 p = vec2(float(i), float(j)) / 5.0 + 0.1;
            float d = length(uv - p);

            if (d > 0.5) continue;
            if (bestDist < 0.01) break;

            float weight = 1.0 / (d + 0.01);
            totalWeight += weight;

            if (d < bestDist) {
                bestDist = d;
                bestPos = p;
                bestIdx = j * 5 + i;
            }
        }
        if (bestDist < 0.01) break;
    }

    float val = bestDist * 2.0 + float(bestIdx) * 0.01;
    vec3 col = vec3(fract(val), bestPos.x, bestPos.y);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
