#version 460

void main() {
    int base = gl_BaseVertex;
    gl_Position = vec4(float(base));
}
