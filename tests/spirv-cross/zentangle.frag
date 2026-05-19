#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test zentangle pattern (structured doodle art)
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    vec2 p = uv * 6.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    float h = hash(id);
    
    vec3 paper = vec3(0.95, 0.92, 0.88);
    vec3 ink = vec3(0.05, 0.04, 0.03);
    
    // Different pattern per cell
    float pattern = 0.0;
    
    float t = h;
    if (t < 0.2) {
        // Parallel diagonal lines
        float stripe = sin((fp.x + fp.y) * 30.0) * 0.5 + 0.5;
        pattern = smoothstep(0.5, 0.52, stripe);
    } else if (t < 0.4) {
        // Concentric circles
        float cr = length(fp - 0.5);
        float rings = sin(cr * 25.0) * 0.5 + 0.5;
        pattern = smoothstep(0.5, 0.52, rings) * step(0.05, cr);
    } else if (t < 0.6) {
        // Crosshatch
        float sx = sin(fp.x * 20.0) * 0.5 + 0.5;
        float sy = sin(fp.y * 20.0) * 0.5 + 0.5;
        pattern = smoothstep(0.5, 0.52, sx) * smoothstep(0.5, 0.52, sy);
    } else if (t < 0.8) {
        // Dots grid
        vec2 dp = fract(fp * 4.0) - 0.5;
        float d = length(dp);
        pattern = smoothstep(0.15, 0.12, d);
    } else {
        // Wavy horizontal lines
        float wave = sin(fp.y * 30.0 + sin(fp.x * 8.0) * 1.5) * 0.5 + 0.5;
        pattern = smoothstep(0.5, 0.52, wave);
    }
    
    // Cell border
    float border = 1.0 - step(0.02, fp.x) * step(fp.x, 0.98) *
                            step(0.02, fp.y) * step(fp.y, 0.98);
    
    vec3 col = paper;
    col = mix(col, ink, pattern);
    col = mix(col, ink * 0.5, border);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
