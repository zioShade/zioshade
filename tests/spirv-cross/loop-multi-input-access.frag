#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Loop with multiple input variable accesses across different scopes
    float sum = 0.0;
    for (int i = 0; i < 5; i++) {
        float fx = uv.x * float(i);
        if (fx > 2.0) {
            sum += fx * uv.y;  // use both uv.x and uv.y inside loop
            break;
        }
        sum += fx * 0.1;
    }
    // Use uv after loop
    fragColor = vec4(sum, uv.x + uv.y, uv.x - uv.y, 1.0);
}
