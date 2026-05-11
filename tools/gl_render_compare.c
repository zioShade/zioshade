// OpenGL GLSL Rendering Comparison Tool (using glad from wintty)
// Compares rendering of glslpp vs spirv-cross GLSL output.
//
// Build:
//   gcc -o gl_render_compare.exe tools/gl_render_compare.c \
//       <wintty_path>/vendor/glad/src/gl.c \
//       -I <wintty_path>/vendor/glad/include \
//       -lopengl32 -lgdi32 -luser32
//
// Usage:
//   gl_render_compare.exe <glslpp.glsl> <spirvcross.glsl> [W] [H]

#include <windows.h>
#include <glad/glad.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char* vertex_shader = 
    "#version 430\n"
    "out vec2 vUV;\n"
    "void main() {\n"
    "    vec2 pos;\n"
    "    pos.x = (gl_VertexID == 2) ? 3.0 : -1.0;\n"
    "    pos.y = (gl_VertexID == 0) ? -3.0 : 1.0;\n"
    "    gl_Position = vec4(pos, 0.0, 1.0);\n"
    "    vUV = pos * 0.5 + 0.5;\n"
    "}\n";

static char* read_file(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char* buf = (char*)malloc(len + 1);
    fread(buf, 1, len, f);
    buf[len] = 0;
    fclose(f);
    return buf;
}

static GLuint compile_shader(GLuint prog, GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint success;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &success);
    if (!success) {
        char log[2048];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "Shader compile error:\n%s\n", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static GLuint create_program(const char* vert_src, const char* frag_src) {
    GLuint prog = glCreateProgram();
    GLuint vs = compile_shader(prog, GL_VERTEX_SHADER, vert_src);
    if (!vs) { glDeleteProgram(prog); return 0; }
    GLuint fs = compile_shader(prog, GL_FRAGMENT_SHADER, frag_src);
    if (!fs) { glDeleteShader(vs); glDeleteProgram(prog); return 0; }
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    GLint success;
    glGetProgramiv(prog, GL_LINK_STATUS, &success);
    if (!success) {
        char log[2048];
        glGetProgramInfoLog(prog, sizeof(log), NULL, log);
        fprintf(stderr, "Program link error:\n%s\n", log);
        glDeleteProgram(prog); prog = 0;
    }
    glDeleteShader(vs);
    glDeleteShader(fs);
    return prog;
}

static void* wgl_load_func(const char* name) {
    return (void*)wglGetProcAddress(name);
}

int main(int argc, char* argv[]) {
    if (argc < 3) {
        printf("Usage: gl_render_compare <glslpp.glsl> <spirvcross.glsl> [W] [H]\n");
        return 1;
    }
    int W = argc > 3 ? atoi(argv[3]) : 256;
    int H = argc > 4 ? atoi(argv[4]) : 256;

    char* frag1 = read_file(argv[1]);
    char* frag2 = read_file(argv[2]);
    if (!frag1 || !frag2) {
        fprintf(stderr, "ERROR: Could not read shader files\n");
        return 1;
    }
    printf("glslpp GLSL: %zu bytes\n", strlen(frag1));
    printf("spirv-cross GLSL: %zu bytes\n", strlen(frag2));

    // Create hidden OpenGL window
    WNDCLASSA wc = {};
    wc.lpfnWndProc = DefWindowProcA;
    wc.lpszClassName = "GLCmp";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("GLCmp", "", WS_POPUP, 0, 0, 1024, 1024, NULL, NULL, NULL, NULL);
    HDC hdc = GetDC(hwnd);
    PIXELFORMATDESCRIPTOR pfd = {};
    pfd.nSize = sizeof(pfd); pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA; pfd.cColorBits = 32;
    int pf = ChoosePixelFormat(hdc, &pfd);
    SetPixelFormat(hdc, pf, &pfd);
    HGLRC hglrc = wglCreateContext(hdc);
    wglMakeCurrent(hdc, hglrc);

    // Load GL functions via glad
    int gl_ok = gladLoadGL();
    if (!gl_ok) {
        fprintf(stderr, "ERROR: gladLoadGL failed\n");
        return 1;
    }
    printf("OpenGL %d.%d loaded\n", GLVersion.major, GLVersion.minor);
    GLint maxTexSize;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTexSize);
    printf("GL_MAX_TEXTURE_SIZE: %d\n", maxTexSize);
    GLint maxRenderSize;
    glGetIntegerv(GL_MAX_RENDERBUFFER_SIZE, &maxRenderSize);
    printf("GL_MAX_RENDERBUFFER_SIZE: %d\n", maxRenderSize);
    if (GLVersion.major < 4) {
        fprintf(stderr, "ERROR: Need OpenGL 4.3+, got %d.%d\n",
                GLVersion.major, GLVersion.minor);
        return 1;
    }

    // Compile shaders
    printf("Compiling glslpp GLSL...\n");
    GLuint prog1 = create_program(vertex_shader, frag1);
    if (!prog1) { fprintf(stderr, "glslpp GLSL compilation failed\n"); return 1; }
    printf("Compiling spirv-cross GLSL...\n");
    GLuint prog2 = create_program(vertex_shader, frag2);
    if (!prog2) { fprintf(stderr, "spirv-cross GLSL compilation failed\n"); return 1; }

    // Create FBO
    // Use FBO with texture attachment for reliable offscreen rendering
    GLuint fbo, tex;
    glGenFramebuffers(1, &fbo);
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    // Validate texture
    int texW, texH;
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &texW);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &texH);
    printf("  FBO texture size: %dx%d\n", texW, texH);
    glBindTexture(GL_TEXTURE_2D, 0); // unbind so it doesn't interfere
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);

    GLenum fbStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    printf("FBO status: 0x%x (COMPLETE=0x8CD5)\n", fbStatus);
    if (fbStatus != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "ERROR: Framebuffer not complete: 0x%x\n", fbStatus);
        return 1;
    }

    GLuint chanTex;

    // Test texture for iChannel0
    glGenTextures(1, &chanTex);
    glBindTexture(GL_TEXTURE_2D, chanTex);
    unsigned char* tp = (unsigned char*)malloc(W * H * 4);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        int i = (y*W+x)*4;
        tp[i+0] = (unsigned char)(x*255/W);
        tp[i+1] = (unsigned char)(y*255/H);
        tp[i+2] = (unsigned char)((x^y)&0xFF);
        tp[i+3] = 255;
    }
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, tp);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    free(tp);

    // Create uniform buffer (Globals struct matching wintty's layout)
    GLuint ubo;
    glGenBuffers(1, &ubo);
    glBindBuffer(GL_UNIFORM_BUFFER, ubo);
    {
        // 4492 bytes matching the wintty Globals struct
        size_t ubo_size = 4492;
        unsigned char* ubo_data = (unsigned char*)calloc(1, ubo_size);
        float* f = (float*)ubo_data;
        f[0] = (float)W;   // resolution.x
        f[1] = (float)H;   // resolution.y
        f[2] = 1.0f;       // resolution.z
        f[3] = 0.5f;       // time
        f[4] = 1.0f/60.0f; // time_delta
        f[5] = 60.0f;      // frame_rate
        int* i32 = (int*)ubo_data;
        i32[6] = 1;        // frame
        f[40] = 128.0f;    // mouse.x
        f[41] = 128.0f;    // mouse.y
        glBufferData(GL_UNIFORM_BUFFER, ubo_size, ubo_data, GL_STATIC_DRAW);
        free(ubo_data);
    }
    // Bind to binding point 1 (matching layout(binding=1))
    glBindBufferBase(GL_UNIFORM_BUFFER, 1, ubo);
    { GLenum e = glGetError(); if (e) printf("  GL error after UBO setup: 0x%x\n", e); }

    glViewport(0, 0, W, H);

    // Create a VAO (required for core profile even if we don't use vertex attributes)
    GLuint vao;
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);

    unsigned char* px1 = (unsigned char*)malloc(W*H*4);
    unsigned char* px2 = (unsigned char*)malloc(W*H*4);

    // Render glslpp
    printf("Rendering glslpp...\n");
    glClearColor(0,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(prog1);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, chanTex);
    GLint loc;
    if ((loc = glGetUniformLocation(prog1, "iChannel0")) >= 0) { glUniform1i(loc, 0); printf("  Set iChannel0 = 0\n"); }
    else printf("  iChannel0 location: %d\n", loc);
    if ((loc = glGetUniformLocation(prog1, "uTex")) >= 0) glUniform1i(loc, 0);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    { GLenum e = glGetError(); if (e) printf("  GL error after draw1: 0x%x\n", e); }
    glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px1);
    { GLenum e2 = glGetError(); if (e2) printf("  GL error after readpixels1: 0x%x\n", e2); }
    printf("  First 4 pixels: %d %d %d %d | %d %d %d %d\n", px1[0],px1[1],px1[2],px1[3], px1[4],px1[5],px1[6],px1[7]);
    GLenum err = glGetError();
    if (err) printf("  GL error after render 1: 0x%x\n", err);

    // Render spirv-cross
    printf("Rendering spirv-cross...\n");
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(prog2);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, chanTex);
    if ((loc = glGetUniformLocation(prog2, "iChannel0")) >= 0) glUniform1i(loc, 0);
    if ((loc = glGetUniformLocation(prog2, "uTex")) >= 0) glUniform1i(loc, 0);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px2);

    // Compare
    int maxDiff = 0, totalDiff = 0, diffPixels = 0, nb1 = 0, nb2 = 0;
    for (int i = 0; i < W*H; i++) {
        int j = i*4;
        if (px1[j]||px1[j+1]||px1[j+2]) nb1++;
        if (px2[j]||px2[j+1]||px2[j+2]) nb2++;
        for (int c = 0; c < 3; c++) {
            int d = abs((int)px1[j+c]-(int)px2[j+c]);
            if (d > maxDiff) maxDiff = d;
            totalDiff += d;
        }
        if (px1[j]!=px2[j]||px1[j+1]!=px2[j+1]||px1[j+2]!=px2[j+2]) diffPixels++;
    }
    printf("\n=== Results ===\n");
    printf("Resolution: %dx%d\n", W, H);
    printf("glslpp non-black: %d/%d\n", nb1, W*H);
    printf("spirv-cross non-black: %d/%d\n", nb2, W*H);
    printf("Different pixels: %d/%d\n", diffPixels, W*H);
    printf("Max channel diff: %d\n", maxDiff);
    printf("Avg channel diff: %.4f\n", (float)totalDiff/(W*H*3));
    printf("%s\n", maxDiff<=1 ? "MATCH (<=1 per-channel)" : "DIFFER");

    // Cleanup
    free(px1); free(px2);
    glDeleteTextures(1, &tex); glDeleteTextures(1, &chanTex);
    glDeleteFramebuffers(1, &fbo);
    glDeleteBuffers(1, &ubo);
    glDeleteProgram(prog1); glDeleteProgram(prog2);
    wglMakeCurrent(NULL, NULL); wglDeleteContext(hglrc);
    DestroyWindow(hwnd);
    free(frag1); free(frag2);
    return maxDiff <= 1 ? 0 : 1;
}
