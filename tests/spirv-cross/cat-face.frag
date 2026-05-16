#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// 2D cat-like face
void main() {
    vec2 p = uv * 2.0 - 1.0;
    
    // Head (ellipse)
    float head = length(p * vec2(0.9, 1.1));
    float face = smoothstep(0.85, 0.8, head);
    
    // Ears (triangles approximated by distance)
    float ear_l = length(p - vec2(-0.5, 0.9)) - 0.35;
    float ear_r = length(p - vec2(0.5, 0.9)) - 0.35;
    float ears = smoothstep(0.05, 0.0, min(ear_l, ear_r));
    
    // Eyes
    float eye_l = length(p - vec2(-0.3, 0.15));
    float eye_r = length(p - vec2(0.3, 0.15));
    float eyes = smoothstep(0.12, 0.1, eye_l) + smoothstep(0.12, 0.1, eye_r);
    
    // Pupils
    float pupil_l = length(p - vec2(-0.3, 0.15));
    float pupil_r = length(p - vec2(0.3, 0.15));
    float pupils = smoothstep(0.06, 0.04, pupil_l) + smoothstep(0.06, 0.04, pupil_r);
    
    // Nose
    float nose = smoothstep(0.05, 0.03, length(p - vec2(0.0, -0.05)));
    
    // Mouth
    float mouth = smoothstep(0.02, 0.0, abs(p.y + 0.15)) * step(0.0, p.x + 0.1) * step(p.x, 0.1);
    
    vec3 col = vec3(0.0);
    col += vec3(0.8, 0.6, 0.3) * max(face, ears);  // fur
    col += vec3(1.0) * eyes;  // white eyes
    col += vec3(0.0) * pupils;  // black pupils
    col += vec3(0.9, 0.4, 0.4) * nose;  // pink nose
    col += vec3(0.0) * mouth;  // mouth line
    
    fragColor = vec4(col, 1.0);
}
