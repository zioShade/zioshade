#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // While loop with return + load after loop
    int count = 0;
    while (count < 5) {
        vec2 p = uv * float(count + 1);
        if (p.x > 3.0) {
            fragColor = vec4(p, 0.0, 1.0);
            return;
        }
        count++;
    }
    fragColor = vec4(uv, 0.5, 1.0);
}
