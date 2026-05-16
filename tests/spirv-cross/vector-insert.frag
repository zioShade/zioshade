#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// OpVectorInsert dynamic test
void main() {
    vec4 col = vec4(0.0);
    col.x = uv.x;
    col.y = uv.y;
    col.z = uv.x * uv.y;
    col.w = 1.0;
    
    // Dynamic index selection
    int idx = int(uv.x * 3.0);
    vec4 highlight = col;
    if (idx == 0) highlight.x = 1.0;
    else if (idx == 1) highlight.y = 1.0;
    else highlight.z = 1.0;
    
    fragColor = vec4(highlight);
}
