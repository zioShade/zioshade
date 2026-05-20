#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // DNA base pair coloring
    float t = uv.x;
    float y = uv.y;
    // Helix backbone
    float backbone_y1 = 5.0 + sin(t * 3.0) * 2.0;
    float backbone_y2 = 5.0 - sin(t * 3.0) * 2.0;
    float b1 = smoothstep(0.1, 0.08, abs(y - backbone_y1));
    float b2 = smoothstep(0.1, 0.08, abs(y - backbone_y2));
    // Base pairs (connections)
    float pair_y1 = backbone_y1;
    float pair_y2 = backbone_y2;
    float mid_y = (pair_y1 + pair_y2) * 0.5;
    float half_dist = abs(pair_y1 - pair_y2) * 0.5;
    float pair = smoothstep(0.03, 0.02, abs(y - mid_y)) * step(half_dist, 2.0);
    // Color bases by position
    float base_id = floor(fract(t * 2.0) * 4.0);
    vec3 col = vec3(0.02, 0.02, 0.05);
    col += vec3(0.3, 0.3, 0.8) * (b1 + b2);
    // A-T pairs (red-blue), G-C pairs (green-yellow)
    vec3 pair_col = base_id < 1.0 ? vec3(0.9, 0.2, 0.2) :
                    base_id < 2.0 ? vec3(0.2, 0.5, 0.9) :
                    base_id < 3.0 ? vec3(0.2, 0.8, 0.3) :
                    vec3(0.9, 0.8, 0.2);
    col += pair_col * pair * 0.5;
    fragColor = vec4(col, 1.0);
}
