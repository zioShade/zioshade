#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test cross-stitch embroidery pattern
void main() {
    vec2 p = uv * 32.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Aida cloth background
    vec3 cloth = vec3(0.85, 0.82, 0.75);
    float weave_x = smoothstep(0.1, 0.0, abs(fp.x - 0.5)) * 0.05;
    float weave_y = smoothstep(0.1, 0.0, abs(fp.y - 0.5)) * 0.05;
    cloth -= weave_x + weave_y;
    
    // Cross stitch pattern: X shape per cell
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    
    // Only stitch some cells (heart shape)
    vec2 cuv = id / 32.0;
    vec2 hp = cuv - vec2(0.5, 0.4);
    float heart = length(hp * vec2(1.0, 1.3));
    float heart_shape = smoothstep(0.3, 0.28, heart);
    
    // Stitches only where heart shape exists
    float stitch_mask = heart_shape * step(0.5, h + 0.3);
    
    // X stitch: two diagonal lines
    float d1 = abs(fp.x - fp.y);
    float d2 = abs(fp.x + fp.y - 1.0);
    float stitch = smoothstep(0.1, 0.06, min(d1, d2));
    
    // Thread color: reds for heart
    float shade = fract(sin(dot(id, vec2(269.5, 183.3))) * 43758.5);
    vec3 thread = mix(vec3(0.8, 0.15, 0.1), vec3(0.9, 0.3, 0.2), shade);
    
    vec3 col = cloth;
    col = mix(col, thread, stitch * stitch_mask);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
