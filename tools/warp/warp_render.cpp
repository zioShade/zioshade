// warp_render.cpp — HLSL RENDER verification on the REAL Direct3D path.
//
// Renders two precompiled pixel shaders (DXIL .cso) with a shared fullscreen-
// triangle vertex shader on the D3D12 WARP software rasterizer, reads back the
// render targets, and diffs pixels. This is the Windows counterpart of
// tools/ShaderCompare.swift (Metal): same 256x256 fullscreen-triangle setup, same
// "MATCH (<=1 per-channel)" verdict, so a shader that RENDER-MATCHes on Metal and
// on WARP is verified on both the Vulkan/Metal and the DXIL/D3D12 runtimes.
//
// WARP (d3d10warp.dll, in the Windows SDK) executes the full D3D12 pipeline on the
// CPU, so this needs no GPU — but it DOES exercise the real DXC->DXIL->D3D12 path
// that wintty ships, which macOS cannot. That is the whole point of running it here.
//
// Usage:  warp_render.exe <vs.cso> <psA.cso> <psB.cso> [out_prefix]
//   exit 0 + "MATCH"  = the two pixel shaders render the same image
//   exit 1 + "DIFFER" = a real pixel divergence (an HLSL miscompile)
//   exit 2            = setup/compile/pipeline error (treat as skip)
//
// Build (x64 Native Tools cmd, Windows SDK on PATH):
//   cl /std:c++17 /EHsc /O2 warp_render.cpp /link d3d12.lib dxgi.lib
//
// The shaders are self-contained fragment shaders (gl_FragCoord / SV_Position only);
// an empty root signature is used, matching that class. A shader that needs a
// cbuffer/texture will fail PSO creation and exit 2 (skip), same as the Metal side.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <vector>
#include <string>
#include <cstdio>
#include <cstdlib>
#include <cmath>

// Minimal ComPtr so we don't depend on WRL.
template <class T> struct CP {
    T* p = nullptr;
    ~CP() { if (p) p->Release(); }
    T** operator&() { return &p; }
    T* operator->() const { return p; }
    operator T*() const { return p; }
    T* get() const { return p; }
};

static const UINT W = 256, H = 256;

static bool readFile(const char* path, std::vector<char>& out) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return false; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    out.resize((size_t)n);
    size_t rd = fread(out.data(), 1, (size_t)n, f); fclose(f);
    return rd == (size_t)n && n > 0;
}

#define HRCHECK(hr, msg) do { if (FAILED(hr)) { fprintf(stderr, "%s (hr=0x%08lx)\n", msg, (unsigned long)(hr)); return 2; } } while(0)

// Render one pixel shader with the shared VS; fill `pixels` (W*H*4, RGBA8).
//
// Depth mode (probeVs/probePs non-empty): verifies a DEPTH-WRITING pixel shader
// (SV_Depth / SV_DepthLessEqual / SV_DepthGreaterEqual) end to end on WARP. A
// D32 depth attachment is bound, cleared to `depthClear`, and the draw runs with
// the depth test enabled (LESS_EQUAL, write on) so only pixels whose WRITTEN
// depth passes against the clear survive. A second draw (probeVs + probePs, LESS
// func, write off, probeVs carries a spatially varying z) then composites green
// wherever the stored depth exceeds the probe z, making the final image a 2D
// fingerprint of the values the shader under test actually exported. A dropped,
// clamped, or ignored depth write changes that fingerprint. Both sides of the
// differential (A and B) go through the same two-draw path.
static int renderOne(ID3D12Device* dev, ID3D12CommandQueue* queue,
                     const std::vector<char>& vs, const std::vector<char>& ps,
                     std::vector<unsigned char>& pixels,
                     const std::vector<char>& probeVs = std::vector<char>(),
                     const std::vector<char>& probePs = std::vector<char>(),
                     float depthClear = 0.3f) {
    const bool depthMode = !probeVs.empty() && !probePs.empty();
    // Root signature with one root CBV at b0. Self-contained shaders don't
    // reference it (a root signature may be a superset of what a shader uses);
    // uniform-matrix shaders (`cbuffer A : register(b0)`) read the known matrix we
    // bind below, so their multiply gets render-verified too. A single mat4 at b0
    // has an unambiguous layout, so this does not risk manufacturing a layout-
    // mismatch false positive (both zioshade's and SPIRV-Cross's HLSL read the same
    // CBV; any packing artifact is identical on both sides and cancels). (#498)
    CP<ID3D12RootSignature> rootSig;
    {
        D3D12_ROOT_PARAMETER rp = {};
        rp.ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
        rp.Descriptor.ShaderRegister = 0; // b0
        rp.Descriptor.RegisterSpace = 0;
        rp.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        D3D12_ROOT_SIGNATURE_DESC rsd = {};
        rsd.NumParameters = 1;
        rsd.pParameters = &rp;
        rsd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
        CP<ID3DBlob> sig, err;
        HRESULT hr = D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &sig, &err);
        HRCHECK(hr, "SerializeRootSignature");
        hr = dev->CreateRootSignature(0, sig->GetBufferPointer(), sig->GetBufferSize(),
                                      IID_PPV_ARGS(&rootSig));
        HRCHECK(hr, "CreateRootSignature");
    }

    // Graphics PSO: fullscreen triangle, no input layout, one RGBA8 target.
    // Depth mode enables the depth test (LESS_EQUAL, write on) against D32.
    CP<ID3D12PipelineState> pso;
    CP<ID3D12PipelineState> probePso;
    {
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pd = {};
        pd.pRootSignature = rootSig.get();
        pd.VS = { vs.data(), vs.size() };
        pd.PS = { ps.data(), ps.size() };
        pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
        pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
        pd.RasterizerState.DepthClipEnable = TRUE;
        pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
        pd.DepthStencilState.DepthEnable = depthMode ? TRUE : FALSE;
        pd.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL;
        pd.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS_EQUAL;
        pd.DepthStencilState.StencilEnable = FALSE;
        pd.SampleMask = UINT_MAX;
        pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        pd.NumRenderTargets = 1;
        pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
        pd.DSVFormat = depthMode ? DXGI_FORMAT_D32_FLOAT : DXGI_FORMAT_UNKNOWN;
        pd.SampleDesc.Count = 1;
        HRESULT hr = dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pso));
        HRCHECK(hr, "CreateGraphicsPipelineState (shader needs resources? -> skip)");
        if (depthMode) {
            // Probe pass: reads the stored depth (LESS, no write) with its own VS
            // (spatially varying z) and a plain green PS.
            pd.VS = { probeVs.data(), probeVs.size() };
            pd.PS = { probePs.data(), probePs.size() };
            pd.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;
            pd.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
            hr = dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&probePso));
            HRCHECK(hr, "CreateGraphicsPipelineState (probe)");
        }
    }

    // Render-target texture.
    CP<ID3D12Resource> rt;
    {
        D3D12_HEAP_PROPERTIES hp = {}; hp.Type = D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC rd = {};
        rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        rd.Width = W; rd.Height = H; rd.DepthOrArraySize = 1; rd.MipLevels = 1;
        rd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; rd.SampleDesc.Count = 1;
        rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
        rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        D3D12_CLEAR_VALUE cv = {}; cv.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        cv.Color[0] = 0; cv.Color[1] = 0; cv.Color[2] = 0; cv.Color[3] = 1;
        HRESULT hr = dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd,
            D3D12_RESOURCE_STATE_RENDER_TARGET, &cv, IID_PPV_ARGS(&rt));
        HRCHECK(hr, "CreateCommittedResource(rt)");
    }

    // RTV heap + view.
    CP<ID3D12DescriptorHeap> rtvHeap;
    {
        D3D12_DESCRIPTOR_HEAP_DESC hd = {}; hd.NumDescriptors = 1;
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        HRESULT hr = dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&rtvHeap));
        HRCHECK(hr, "CreateDescriptorHeap(rtv)");
    }
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = rtvHeap->GetCPUDescriptorHandleForHeapStart();
    dev->CreateRenderTargetView(rt.get(), nullptr, rtv);

    // Depth attachment + DSV (depth mode only). The heap lives to the end of
    // renderOne; the CPU descriptor only needs to stay valid until the command
    // list has executed (the fence wait below).
    CP<ID3D12Resource> dtex;
    CP<ID3D12DescriptorHeap> dsvHeap;
    D3D12_CPU_DESCRIPTOR_HANDLE dsv = {};
    if (depthMode) {
        D3D12_HEAP_PROPERTIES hp = {}; hp.Type = D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC rd = {};
        rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        rd.Width = W; rd.Height = H; rd.DepthOrArraySize = 1; rd.MipLevels = 1;
        rd.Format = DXGI_FORMAT_D32_FLOAT; rd.SampleDesc.Count = 1;
        rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
        rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
        D3D12_CLEAR_VALUE cv = {}; cv.Format = DXGI_FORMAT_D32_FLOAT;
        cv.DepthStencil.Depth = depthClear;
        HRESULT hr = dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd,
            D3D12_RESOURCE_STATE_DEPTH_WRITE, &cv, IID_PPV_ARGS(&dtex));
        HRCHECK(hr, "CreateCommittedResource(depth)");
        D3D12_DESCRIPTOR_HEAP_DESC hd = {}; hd.NumDescriptors = 1;
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_DSV;
        hr = dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&dsvHeap));
        HRCHECK(hr, "CreateDescriptorHeap(dsv)");
        dsv = dsvHeap->GetCPUDescriptorHandleForHeapStart();
        dev->CreateDepthStencilView(dtex.get(), nullptr, dsv);
    }

    // Readback buffer. W*4 = 1024 is 256-aligned, so no per-row padding.
    const UINT rowPitch = W * 4;
    CP<ID3D12Resource> readback;
    {
        D3D12_HEAP_PROPERTIES hp = {}; hp.Type = D3D12_HEAP_TYPE_READBACK;
        D3D12_RESOURCE_DESC rd = {};
        rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        rd.Width = (UINT64)rowPitch * H; rd.Height = 1; rd.DepthOrArraySize = 1;
        rd.MipLevels = 1; rd.Format = DXGI_FORMAT_UNKNOWN; rd.SampleDesc.Count = 1;
        rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        HRESULT hr = dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd,
            D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&readback));
        HRCHECK(hr, "CreateCommittedResource(readback)");
    }

    CP<ID3D12CommandAllocator> alloc;
    HRCHECK(dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&alloc)), "CreateCommandAllocator");

    // Constant buffer bound at b0: 64 DISTINCT floats (1..64) filling the whole
    // 256-byte CBV. The first 16 are the known asymmetric mat4 in std140
    // column-major layout (columns 0..3 = {1..4},{5..8},{9..12},{13..16}); its
    // transpose is distinct, so a wrong-major multiply renders differently. The
    // remaining floats keep every uniform member past offset 64 render-
    // discriminating too: a shader that reads a second matrix / array / struct
    // tail would otherwise see zeros and a miscompiled read could silently
    // match (the loop-13 lesson, made permanent; validated on WARP there).
    CP<ID3D12Resource> cbuf;
    {
        D3D12_HEAP_PROPERTIES hp = {}; hp.Type = D3D12_HEAP_TYPE_UPLOAD;
        D3D12_RESOURCE_DESC rd = {};
        rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        rd.Width = 256; rd.Height = 1; rd.DepthOrArraySize = 1; rd.MipLevels = 1;
        rd.Format = DXGI_FORMAT_UNKNOWN; rd.SampleDesc.Count = 1;
        rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        HRCHECK(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd,
            D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&cbuf)), "CreateCommittedResource(cbuf)");
        float m[64] = {0};
        for (int i = 0; i < 64; i++) m[i] = (float)(i + 1); // 1..64, all distinct
        void* p = nullptr; D3D12_RANGE nr = {0, 0};
        HRCHECK(cbuf->Map(0, &nr, &p), "Map cbuf");
        memcpy(p, m, sizeof(m));
        cbuf->Unmap(0, nullptr);
    }

    CP<ID3D12GraphicsCommandList> cl;
    HRCHECK(dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc.get(), pso.get(), IID_PPV_ARGS(&cl)), "CreateCommandList");

    D3D12_VIEWPORT vp = { 0, 0, (float)W, (float)H, 0, 1 };
    D3D12_RECT sc = { 0, 0, (LONG)W, (LONG)H };
    cl->SetGraphicsRootSignature(rootSig.get());
    cl->SetGraphicsRootConstantBufferView(0, cbuf->GetGPUVirtualAddress());
    cl->RSSetViewports(1, &vp);
    cl->RSSetScissorRects(1, &sc);
    cl->OMSetRenderTargets(1, &rtv, FALSE, depthMode ? &dsv : nullptr);
    const float clear[4] = { 0, 0, 0, 1 };
    cl->ClearRenderTargetView(rtv, clear, 0, nullptr);
    if (depthMode) {
        // Depth is pre-cleared by the resource's optimized clear value; clear it
        // explicitly anyway so the state transition covers both clears.
        cl->ClearDepthStencilView(dsv, D3D12_CLEAR_FLAG_DEPTH, depthClear, 0, 0, nullptr);
    }
    cl->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    cl->DrawInstanced(3, 1, 0, 0);
    if (depthMode) {
        // Probe pass over the stored depth: composite green where stored > probe z.
        cl->SetPipelineState(probePso.get());
        cl->DrawInstanced(3, 1, 0, 0);
    }

    // RT -> COPY_SOURCE, copy into the readback buffer.
    D3D12_RESOURCE_BARRIER b = {};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = rt.get();
    b.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
    b.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    cl->ResourceBarrier(1, &b);

    D3D12_TEXTURE_COPY_LOCATION dst = {}; dst.pResource = readback.get();
    dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint.Footprint.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    dst.PlacedFootprint.Footprint.Width = W;
    dst.PlacedFootprint.Footprint.Height = H;
    dst.PlacedFootprint.Footprint.Depth = 1;
    dst.PlacedFootprint.Footprint.RowPitch = rowPitch;
    D3D12_TEXTURE_COPY_LOCATION src = {}; src.pResource = rt.get();
    src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; src.SubresourceIndex = 0;
    cl->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    HRCHECK(cl->Close(), "Close command list");

    ID3D12CommandList* lists[] = { cl.get() };
    queue->ExecuteCommandLists(1, lists);

    // Fence wait.
    CP<ID3D12Fence> fence;
    HRCHECK(dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)), "CreateFence");
    HANDLE ev = CreateEvent(nullptr, FALSE, FALSE, nullptr);
    HRCHECK(queue->Signal(fence.get(), 1), "Signal");
    if (fence->GetCompletedValue() < 1) { fence->SetEventOnCompletion(1, ev); WaitForSingleObject(ev, INFINITE); }
    CloseHandle(ev);

    // Map + copy out.
    void* mapped = nullptr; D3D12_RANGE rr = { 0, (SIZE_T)rowPitch * H };
    HRCHECK(readback->Map(0, &rr, &mapped), "Map readback");
    pixels.resize((size_t)W * H * 4);
    memcpy(pixels.data(), mapped, pixels.size());
    D3D12_RANGE nw = { 0, 0 };
    readback->Unmap(0, &nw);
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 4) { fprintf(stderr, "usage: warp_render <vs.cso> <psA.cso> <psB.cso> [out_prefix | probeVs.cso probePs.cso [depthClear]]\n"); return 2; }
    std::vector<char> vs, psA, psB;
    if (!readFile(argv[1], vs) || !readFile(argv[2], psA) || !readFile(argv[3], psB)) return 2;
    // Depth mode: argv[4]/argv[5] carry the probe pass shaders (distinguished from
    // the legacy out_prefix by the .cso suffix). argv[6] is the depth clear value.
    std::vector<char> probeVs, probePs;
    float depthClear = 0.3f;
    bool depthMode = false;
    if (argc >= 6 && argv[4] && strstr(argv[4], ".cso") && argv[5] && strstr(argv[5], ".cso")) {
        if (!readFile(argv[4], probeVs) || !readFile(argv[5], probePs)) return 2;
        depthMode = true;
        if (argc >= 7 && argv[6]) depthClear = (float)atof(argv[6]);
    }

    CP<IDXGIFactory4> factory;
    HRCHECK(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)), "CreateDXGIFactory2");
    CP<IDXGIAdapter> warp;
    HRCHECK(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp)), "EnumWarpAdapter");
    CP<ID3D12Device> dev;
    HRCHECK(D3D12CreateDevice(warp.get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&dev)), "D3D12CreateDevice(WARP)");
    CP<ID3D12CommandQueue> queue;
    { D3D12_COMMAND_QUEUE_DESC qd = {}; qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
      HRCHECK(dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&queue)), "CreateCommandQueue"); }

    std::vector<unsigned char> a, b;
    int r1 = depthMode ? renderOne(dev.get(), queue.get(), vs, psA, a, probeVs, probePs, depthClear)
                       : renderOne(dev.get(), queue.get(), vs, psA, a);
    if (r1) return r1;
    int r2 = depthMode ? renderOne(dev.get(), queue.get(), vs, psB, b, probeVs, probePs, depthClear)
                       : renderOne(dev.get(), queue.get(), vs, psB, b);
    if (r2) return r2;

    // Optional PPM dump of both renders (diagnostics; the legacy [out_prefix]
    // argument, or in depth mode argv[7]): writes <prefix>A.ppm / <prefix>B.ppm.
    const char* dumpPrefix = nullptr;
    if (!depthMode && argc >= 5 && argv[4]) dumpPrefix = argv[4];
    if (depthMode && argc >= 8 && argv[7]) dumpPrefix = argv[7];
    if (dumpPrefix) {
        for (int k = 0; k < 2; k++) {
            const std::vector<unsigned char>& px = k ? b : a;
            std::string path = std::string(dumpPrefix) + (k ? "B.ppm" : "A.ppm");
            FILE* f = fopen(path.c_str(), "wb");
            if (f) {
                fprintf(f, "P6\n%u %u\n255\n", W, H);
                for (size_t i = 0; i < px.size(); i += 4) {
                    unsigned char rgb[3] = { px[i], px[i + 1], px[i + 2] };
                    fwrite(rgb, 1, 3, f);
                }
                fclose(f);
                printf("dumped %s\n", path.c_str());
            }
        }
    }

    long maxD = 0, total = 0, diffPx = 0;
    for (size_t i = 0; i < a.size(); i++) {
        long d = labs((long)a[i] - (long)b[i]);
        if (d > maxD) maxD = d;
        total += d;
        // Count a pixel once when ANY of its channels differs. The old form keyed
        // on (i % 4) == 0, so a green, blue, or alpha-only divergence reported
        // "Different: 0" next to a DIFFER verdict, which misleads during triage.
        if (d > 0 && (i % 4) == 3) {
            bool any = false;
            for (int c = 0; c < 4; c++) any |= a[i - 3 + c] != b[i - 3 + c];
            if (any) diffPx++;
        }
    }
    printf("Resolution: %ux%u  Pixels: %u  Different: %ld\n", W, H, W * H, diffPx);
    printf("Max channel diff: %ld\n", maxD);
    printf("Avg channel diff: %.4f\n", (double)total / (double)a.size());
    bool match = (maxD <= 1);
    printf("%s\n", match ? "MATCH (<=1 per-channel)" : "DIFFER (max diff)");
    return match ? 0 : 1;
}
