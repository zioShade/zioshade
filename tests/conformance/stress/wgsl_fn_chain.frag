#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test chain of function calls (foo calls bar calls baz)
float baz(float x) {
    return x * x + 0.1;
}

float bar(float x) {
    return sin(baz(x)) * 0.5;
}

float foo(float x) {
    return bar(x + 1.0) + bar(x - 1.0);
}

void main() {
    float result = foo(uv.x);
    vec3 color = vec3(result, result * 0.5, baz(uv.y));
    fragColor = vec4(color, 1.0);
}
