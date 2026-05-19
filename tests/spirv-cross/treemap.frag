#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test treemap visualization pattern
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    vec3 col = vec3(0.08);
    
    // Nested rectangles simulating a treemap
    // Level 1: 4 quadrants
    float h_split = 0.45;
    float v_split = 0.55;
    
    vec2 cell1_min = vec2(0.0, 0.0);
    vec2 cell1_max = vec2(h_split, v_split);
    vec2 cell2_min = vec2(h_split, 0.0);
    vec2 cell2_max = vec2(1.0, 0.4);
    vec2 cell3_min = vec2(0.0, v_split);
    vec2 cell3_max = vec2(0.35, 1.0);
    vec2 cell4_min = vec2(0.35, v_split);
    vec2 cell4_max = vec2(1.0, 1.0);
    
    // Check which cell we're in and subdivide further
    float gap = 0.005;
    
    // Cell 1: subdivided into 3 vertical strips
    if (uv.x >= cell1_min.x + gap && uv.x <= cell1_max.x - gap &&
        uv.y >= cell1_min.y + gap && uv.y <= cell1_max.y - gap) {
        float local_x = (uv.x - cell1_min.x) / (cell1_max.x - cell1_min.x);
        float local_y = (uv.y - cell1_min.y) / (cell1_max.y - cell1_min.y);
        float strip = floor(local_x * 3.0);
        float t = strip / 3.0;
        col = mix(vec3(0.2, 0.6, 0.8), vec3(0.1, 0.4, 0.7), t);
        col += 0.1 * hash(vec2(strip, 0.0));
    }
    // Cell 2
    else if (uv.x >= cell2_min.x + gap && uv.x <= cell2_max.x - gap &&
             uv.y >= cell2_min.y + gap && uv.y <= cell2_max.y - gap) {
        float local_y = (uv.y - cell2_min.y) / (cell2_max.y - cell2_min.y);
        float strip = floor(local_y * 2.0);
        col = mix(vec3(0.8, 0.4, 0.2), vec3(0.9, 0.6, 0.3), strip / 2.0);
    }
    // Cell 3
    else if (uv.x >= cell3_min.x + gap && uv.x <= cell3_max.x - gap &&
             uv.y >= cell3_min.y + gap && uv.y <= cell3_max.y - gap) {
        col = vec3(0.5, 0.75, 0.3);
    }
    // Cell 4: subdivided into 2x2
    else if (uv.x >= cell4_min.x + gap && uv.x <= cell4_max.x - gap &&
             uv.y >= cell4_min.y + gap && uv.y <= cell4_max.y - gap) {
        float lx = (uv.x - cell4_min.x) / (cell4_max.x - cell4_min.x);
        float ly = (uv.y - cell4_min.y) / (cell4_max.y - cell4_min.y);
        float sx = floor(lx * 2.0);
        float sy = floor(ly * 2.0);
        float idx = sx + sy * 2.0;
        col = vec3(0.6 + idx * 0.1, 0.3 + idx * 0.05, 0.5 - idx * 0.08);
    }
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
