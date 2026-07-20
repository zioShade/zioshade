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
static int renderOne(ID3D12Device* dev, ID3D12CommandQueue* queue,
                     const std::vector<char>& vs, const std::vector<char>& ps,
                     std::vector<unsigned char>& pixels) {
    // Empty root signature (self-contained shaders bind no resources).
    CP<ID3D12RootSignature> rootSig;
    {
        D3D12_ROOT_SIGNATURE_DESC rsd = {};
        rsd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
        CP<ID3DBlob> sig, err;
        HRESULT hr = D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &sig, &err);
        HRCHECK(hr, "SerializeRootSignature");
        hr = dev->CreateRootSignature(0, sig->GetBufferPointer(), sig->GetBufferSize(),
                                      IID_PPV_ARGS(&rootSig));
        HRCHECK(hr, "CreateRootSignature");
    }

    // Graphics PSO: fullscreen triangle, no input layout, one RGBA8 target.
    CP<ID3D12PipelineState> pso;
    {
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pd = {};
        pd.pRootSignature = rootSig.get();
        pd.VS = { vs.data(), vs.size() };
        pd.PS = { ps.data(), ps.size() };
        pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
        pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
        pd.RasterizerState.DepthClipEnable = TRUE;
        pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
        pd.DepthStencilState.DepthEnable = FALSE;
        pd.DepthStencilState.StencilEnable = FALSE;
        pd.SampleMask = UINT_MAX;
        pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        pd.NumRenderTargets = 1;
        pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
        pd.SampleDesc.Count = 1;
        HRESULT hr = dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pso));
        HRCHECK(hr, "CreateGraphicsPipelineState (shader needs resources? -> skip)");
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
    CP<ID3D12GraphicsCommandList> cl;
    HRCHECK(dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc.get(), pso.get(), IID_PPV_ARGS(&cl)), "CreateCommandList");

    D3D12_VIEWPORT vp = { 0, 0, (float)W, (float)H, 0, 1 };
    D3D12_RECT sc = { 0, 0, (LONG)W, (LONG)H };
    cl->SetGraphicsRootSignature(rootSig.get());
    cl->RSSetViewports(1, &vp);
    cl->RSSetScissorRects(1, &sc);
    cl->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
    const float clear[4] = { 0, 0, 0, 1 };
    cl->ClearRenderTargetView(rtv, clear, 0, nullptr);
    cl->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    cl->DrawInstanced(3, 1, 0, 0);

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
    if (argc < 4) { fprintf(stderr, "usage: warp_render <vs.cso> <psA.cso> <psB.cso> [out_prefix]\n"); return 2; }
    std::vector<char> vs, psA, psB;
    if (!readFile(argv[1], vs) || !readFile(argv[2], psA) || !readFile(argv[3], psB)) return 2;

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
    int r1 = renderOne(dev.get(), queue.get(), vs, psA, a);
    if (r1) return r1;
    int r2 = renderOne(dev.get(), queue.get(), vs, psB, b);
    if (r2) return r2;

    long maxD = 0, total = 0, diffPx = 0;
    for (size_t i = 0; i < a.size(); i++) {
        long d = labs((long)a[i] - (long)b[i]);
        if (d > maxD) maxD = d;
        total += d;
        if (d > 0 && (i % 4) == 0) diffPx++;
    }
    printf("Resolution: %ux%u  Pixels: %u  Different: %ld\n", W, H, W * H, diffPx);
    printf("Max channel diff: %ld\n", maxD);
    printf("Avg channel diff: %.4f\n", (double)total / (double)a.size());
    bool match = (maxD <= 1);
    printf("%s\n", match ? "MATCH (<=1 per-channel)" : "DIFFER (max diff)");
    return match ? 0 : 1;
}
