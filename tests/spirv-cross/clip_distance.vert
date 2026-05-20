#version 450

void main() {
    gl_Position = vec4(1.0);
    gl_ClipDistance[0] = 1.0;
    gl_ClipDistance[1] = 0.0;
    gl_PointSize = 5.0;
}
