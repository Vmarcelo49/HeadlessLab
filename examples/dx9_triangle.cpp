// dx9_triangle.cpp - Renderiza um triângulo colorido em DirectX 9
// Compilado com: x86_64-w64-mingw32-g++-win32 -municode -ld3d9 -ld3dcompiler
// Validado para rodar via Wine + bwrap + Xvfb + llvmpipe (headless, sem GPU física)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>

struct Vertex {
    float x, y, z, rhw;
    DWORD color;
};
#define FVF (D3DFVF_XYZRHW | D3DFVF_DIFFUSE)

LRESULT WINAPI WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hWnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR, int) {
    WNDCLASSEXA wc = { sizeof(wc), CS_CLASSDC, WndProc, 0L, 0L, hInst, NULL, NULL, NULL, NULL, "DX9Test", NULL };
    RegisterClassExA(&wc);

    RECT rc = {0, 0, 800, 600};
    AdjustWindowRect(&rc, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hWnd = CreateWindowExA(0, "DX9Test", "DX9 Headless Test",
        WS_OVERLAPPEDWINDOW, 100, 100, rc.right - rc.left, rc.bottom - rc.top,
        NULL, NULL, hInst, NULL);
    ShowWindow(hWnd, SW_SHOWDEFAULT);
    UpdateWindow(hWnd);

    printf("=== DX9 Test Program ===\n");
    printf("[OK] Window created HWND=%p\n", hWnd);

    IDirect3D9* d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { printf("[FAIL] Direct3DCreate9 failed\n"); return 1; }
    printf("[OK] Direct3DCreate9 succeeded. D3D pointer=%p\n", d3d);

    UINT adapterCount = d3d->GetAdapterCount();
    printf("[INFO] Adapter count: %u\n", adapterCount);
    for (UINT i = 0; i < adapterCount; i++) {
        D3DADAPTER_IDENTIFIER9 id;
        if (SUCCEEDED(d3d->GetAdapterIdentifier(i, 0, &id))) {
            printf("  Adapter %u: %s (driver %s)\n",
                i, id.Description, id.Driver);
        }
    }

    D3DPRESENT_PARAMETERS pp = {};
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferWidth = 800;
    pp.BackBufferHeight = 600;
    pp.BackBufferFormat = D3DFMT_UNKNOWN;

    IDirect3DDevice9* dev = NULL;
    HRESULT hr = d3d->CreateDevice(D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hWnd,
        D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    if (FAILED(hr)) {
        printf("[INFO] HAL failed (hr=0x%08x), trying Ref\n", hr);
        hr = d3d->CreateDevice(D3DADAPTER_DEFAULT, D3DDEVTYPE_REF, hWnd,
            D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev);
    }
    if (FAILED(hr)) { printf("[FAIL] CreateDevice hr=0x%08x\n", hr); return 1; }
    printf("[OK] Direct3D device created. Device=%p, hr=0x%08x\n", dev, hr);

    Vertex verts[3] = {
        { 400.0f, 100.0f, 0.5f, 1.0f, 0xFFFF0000 },
        { 100.0f, 500.0f, 0.5f, 1.0f, 0xFF00FF00 },
        { 700.0f, 500.0f, 0.5f, 1.0f, 0xFF0000FF },
    };

    IDirect3DVertexBuffer9* vb = NULL;
    hr = dev->CreateVertexBuffer(sizeof(verts), 0, FVF, D3DPOOL_DEFAULT, &vb, NULL);
    if (FAILED(hr)) { printf("[FAIL] CreateVertexBuffer hr=0x%08x\n", hr); return 1; }
    void* pLocked = NULL;
    vb->Lock(0, sizeof(verts), &pLocked, 0);
    memcpy(pLocked, verts, sizeof(verts));
    vb->Unlock();
    printf("[OK] Vertex buffer created.\n");

    dev->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE);
    dev->SetRenderState(D3DRS_LIGHTING, FALSE);
    dev->SetRenderState(D3DRS_ALPHABLENDENABLE, FALSE);
    dev->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);

    printf("[OK] Setup complete. Entering message loop.\n");

    MSG msg;
    ZeroMemory(&msg, sizeof(msg));
    int frame = 0;
    while (msg.message != WM_QUIT) {
        if (PeekMessageA(&msg, NULL, 0U, 0U, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        } else {
            hr = dev->Clear(0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(40,40,80), 1.0f, 0);
            if (frame == 0) printf("[INFO] First Clear hr=0x%08x\n", hr);

            hr = dev->BeginScene();
            if (frame == 0) printf("[INFO] BeginScene hr=0x%08x\n", hr);

            dev->SetStreamSource(0, vb, 0, sizeof(Vertex));
            dev->SetFVF(FVF);
            hr = dev->DrawPrimitive(D3DPT_TRIANGLELIST, 0, 1);
            if (frame == 0) printf("[INFO] DrawPrimitive hr=0x%08x\n", hr);

            hr = dev->EndScene();
            if (frame == 0) printf("[INFO] EndScene hr=0x%08x\n", hr);

            hr = dev->Present(NULL, NULL, NULL, NULL);
            if (frame == 0) printf("[INFO] First Present hr=0x%08x\n", hr);

            frame++;
            if (frame == 1) {
                printf("[INFO] Rendering loop running. Screenshot ready.\n");
                fflush(stdout);
            }
            Sleep(100); // ~10fps, baixa CPU
        }
    }
    printf("[INFO] Total frames rendered: %d\n", frame);

    if (vb) vb->Release();
    if (dev) dev->Release();
    if (d3d) d3d->Release();
    UnregisterClassA("DX9Test", hInst);
    return 0;
}
