#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Conway's Game of Life (static pattern)
void main() {
    vec2 cell = floor(uv * 32.0);
    vec2 f = fract(uv * 32.0);
    
    // Static glider pattern
    int x = int(cell.x);
    int y = int(cell.y);
    
    bool alive = false;
    // Glider at (5,5)
    if (x == 5 && y == 6) alive = true;
    if (x == 6 && y == 7) alive = true;
    if (x == 7 && y == 5) alive = true;
    if (x == 7 && y == 6) alive = true;
    if (x == 7 && y == 7) alive = true;
    
    // Block at (15,15)
    if (x == 15 && y == 15) alive = true;
    if (x == 16 && y == 15) alive = true;
    if (x == 15 && y == 16) alive = true;
    if (x == 16 && y == 16) alive = true;
    
    // Blinker at (25,10)
    if (x == 25 && y == 10) alive = true;
    if (x == 26 && y == 10) alive = true;
    if (x == 27 && y == 10) alive = true;
    
    vec3 col = vec3(0.0);
    if (alive) col = vec3(0.2, 0.8, 0.3);
    
    // Grid lines
    float grid = max(step(0.95, f.x), step(0.95, f.y));
    col += vec3(0.05) * grid;
    
    fragColor = vec4(col, 1.0);
}
