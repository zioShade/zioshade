#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// L-system-like tree branching
void main() {
    vec2 p = uv;
    p.x = (p.x - 0.5) * 3.0;
    p.y = p.y * 3.0;
    
    // Trunk
    float trunk = smoothstep(0.05, 0.0, abs(p.x)) * step(0.0, p.y) * step(p.y, 1.5);
    
    // Two branches at y=1.5
    vec2 bp1 = p - vec2(0.0, 1.5);
    float angle1 = 0.5;
    float branch1_x = bp1.x * cos(angle1) - bp1.y * sin(angle1);
    float branch1_y = bp1.x * sin(angle1) + bp1.y * cos(angle1);
    float branch1 = smoothstep(0.04, 0.0, abs(branch1_x)) * step(0.0, branch1_y) * step(branch1_y, 0.8);
    
    float angle2 = -0.5;
    float branch2_x = bp1.x * cos(angle2) - bp1.y * sin(angle2);
    float branch2_y = bp1.x * sin(angle2) + bp1.y * cos(angle2);
    float branch2 = smoothstep(0.04, 0.0, abs(branch2_x)) * step(0.0, branch2_y) * step(branch2_y, 0.8);
    
    float tree = trunk + branch1 + branch2;
    tree = min(tree, 1.0);
    
    vec3 col = vec3(0.05, 0.15, 0.05);  // dark green bg
    col += vec3(0.4, 0.25, 0.1) * tree;  // brown tree
    
    fragColor = vec4(col, 1.0);
}
