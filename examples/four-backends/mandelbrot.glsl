#version 430



layout(location = 0) out vec4 FragColor;

void main()
{
    vec2 v11;
    int v12;
    vec2 v14 = vec2(gl_FragCoord.x, gl_FragCoord.y);
    vec2 v15 = v14 / vec2(128.0);
    vec2 v16 = v15 - vec2(0.5);
    vec2 v17 = v16 * 3.0;
    v11 = vec2(0.0);
    v12 = 0;
    int v18 = 0;
    bool _loopfirst_53 = true;
    while (true)
    {
        if (!_loopfirst_53)
        {
    int v37 = v18 + 1;
        v18 = v37;
        }
        _loopfirst_53 = false;
    bool v19 = v18 < 16;
        if (!(v19)) break;
    vec2 v20 = v11;
    float v21 = v20.x;
    float v22 = v21 * v21;
    float v23 = v20.y;
    float v24 = v23 * v23;
    float v25 = v22 - v24;
    float v26 = v17.x;
    float v27 = v25 + v26;
    float v28 = 2.0 * v21;
    float v29 = v28 * v23;
    float v30 = v17.y;
    float v31 = v29 + v30;
    vec2 v32 = vec2(v27, v31);
    v11 = v32;
    float v33 = dot(v32, v32);
    bool v34 = v33 > 4.0;
        if (v34) break;
    int v35 = v12;
    int v36 = v35 + 1;
    v12 = v36;
    }
    int v38 = v12;
    float v39 = float(v38);
    float v40 = v39 / 16.0;
    float v41 = v40 * v40;
    float v42 = sqrt(v40);
    vec4 v43 = vec4(v40, v41, v42, 1.0);
    FragColor = v43;
    return;
}
