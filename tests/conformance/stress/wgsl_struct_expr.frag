// Tests: struct returned from function used in expression
#version 450
layout(location = 0) out vec4 fragColor;

struct Result { float value; float confidence; };

Result analyze(float x) {
    Result r;
    r.value = sin(x) * 0.5 + 0.5;
    r.confidence = abs(cos(x));
    return r;
}

void main() {
    Result r = analyze(1.0);
    float combined = r.value * r.confidence;
    fragColor = vec4(vec3(combined), 1.0);
}
