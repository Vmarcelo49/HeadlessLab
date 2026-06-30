// dx9_cube.cpp — Rotating textured cube in DirectX 9
// Tests: vertex buffers, index buffers, textures, transform matrices, render loop.
// Compile: x86_64-w64-mingw32-g++-win32 -O2 -o dx9_cube.exe dx9_cube.cpp \
//          -ld3d9 -ld3dcompiler -lgdi32 -luser32 -static-libgcc -static-libstdc++ \
//          -Wl,--subsystem,windows

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <math.h>

// Vertex with position, color, and texture coords
struct Vertex {
    float x, y, z;
    DWORD color;
    float u, v;
};
#define FVF (D3DFVF_XYZ | D3DFVF_DIFFUSE | D3DFVF_TEX1)

// 8 cube vertices (one per corner) with distinct colors and UV coords
static Vertex cube[] = {
    // front face (+Z)
    { -1, -1,  1, 0xFFFF0000, 0, 1 },  // 0
    {  1, -1,  1, 0xFF00FF00, 1, 1 },  // 1
    {  1,  1,  1, 0xFF0000FF, 1, 0 },  // 2
    { -1,  1,  1, 0xFFFFFF00, 0, 0 },  // 3
    // back face (-Z)
    { -1, -1, -1, 0xFFFF00FF, 1, 1 },  // 4
    {  1, -1, -1, 0xFF00FFFF, 0, 1 },  // 5
    {  1,  1, -1, 0xFFFFFFFF, 0, 0 },  // 6
    { -1,  1, -1, 0xFF808080, 1, 0 },  // 7
};

// 12 triangles (2 per face × 6 faces)
static unsigned short indices[] = {
    0,1,2, 0,2,3,    // front
    5,4,7, 5,7,6,    // back
    4,0,3, 4,3,7,    // left
    1,5,6, 1,6,2,    // right
    3,2,6, 3,6,7,    // top
    4,5,1, 4,1,0,    // bottom
};

LRESULT WINAPI WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hWnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR, int) {
    WNDCLASSEXA wc = { sizeof(wc), CS_CLASSDC, WndProc, 0L, 0L, hInst, NULL, NULL, NULL, NULL, "DX9Cube", NULL };
    RegisterClassExA(&wc);

    RECT rc = {0, 0, 800, 600};
    AdjustWindowRect(&rc, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hWnd = CreateWindowExA(0, "DX9Cube", "DX9 Rotating Cube",
        WS_OVERLAPPEDWINDOW, 100, 100, rc.right - rc.left, rc.bottom - rc.top,
        NULL, NULL, hInst, NULL);
    ShowWindow(hWnd, SW_SHOWDEFAULT);
    UpdateWindow(hWnd);

    printf("=== DX9 Rotating Cube ===\n");
    printf("[OK] Window created HWND=%p\n", hWnd);

    IDirect3D9* d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { printf("[FAIL] Direct3DCreate9 failed\n"); return 1; }
    printf("[OK] Direct3DCreate9 succeeded\n");

    D3DPRESENT_PARAMETERS pp = {};
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferWidth = 800;
    pp.BackBufferHeight = 600;
    pp.BackBufferFormat = D3DFMT_UNKNOWN;
    pp.EnableAutoDepthStencil = TRUE;
    pp.AutoDepthStencilFormat = D3DFMT_D16;

    IDirect3DDevice9* dev = NULL;
    HRESULT hr = d3d->CreateDevice(D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hWnd,
        D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    if (FAILED(hr)) {
        printf("[INFO] HAL failed (hr=0x%08x), trying software\n", hr);
        hr = d3d->CreateDevice(D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hWnd,
            D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev);
    }
    if (FAILED(hr)) { printf("[FAIL] CreateDevice hr=0x%08x\n", hr); return 1; }
    printf("[OK] Direct3D device created. hr=0x%08x\n", hr);

    // Create vertex buffer
    IDirect3DVertexBuffer9* vb = NULL;
    dev->CreateVertexBuffer(sizeof(cube), 0, FVF, D3DPOOL_DEFAULT, &vb, NULL);
    void* pLocked = NULL;
    vb->Lock(0, sizeof(cube), &pLocked, 0);
    memcpy(pLocked, cube, sizeof(cube));
    vb->Unlock();
    printf("[OK] Vertex buffer created (8 vertices)\n");

    // Create index buffer
    IDirect3DIndexBuffer9* ib = NULL;
    dev->CreateIndexBuffer(sizeof(indices), 0, D3DFMT_INDEX16, D3DPOOL_DEFAULT, &ib, NULL);
    void* iLocked = NULL;
    ib->Lock(0, sizeof(indices), &iLocked, 0);
    memcpy(iLocked, indices, sizeof(indices));
    ib->Unlock();
    printf("[OK] Index buffer created (12 triangles)\n");

    // Create a checkerboard texture (procedurally generated, 64x64)
    IDirect3DTexture9* tex = NULL;
    dev->CreateTexture(64, 64, 1, 0, D3DFMT_A8R8G8B8, D3DPOOL_MANAGED, &tex, NULL);
    D3DLOCKED_RECT lockedRect;
    tex->LockRect(0, &lockedRect, NULL, 0);
    for (int y = 0; y < 64; y++) {
        unsigned int* row = (unsigned int*)((char*)lockedRect.pBits + y * lockedRect.Pitch);
        for (int x = 0; x < 64; x++) {
            // 8x8 checkerboard with magenta + white
            row[x] = ((x / 8 + y / 8) % 2) ? 0xFFFFFFFF : 0xFFFF00FF;
        }
    }
    tex->UnlockRect(0);
    printf("[OK] Texture created (64x64 checkerboard)\n");

    // Render states
    dev->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE);
    dev->SetRenderState(D3DRS_LIGHTING, FALSE);
    dev->SetRenderState(D3DRS_ZENABLE, TRUE);
    dev->SetTextureStageState(0, D3DTSS_COLOROP, D3DTOP_MODULATE);
    dev->SetTextureStageState(0, D3DTSS_COLORARG1, D3DTA_TEXTURE);
    dev->SetTextureStageState(0, D3DTSS_COLORARG2, D3DTA_DIFFUSE);

    // Set projection matrix
    D3DMATRIX proj;
    float fov = 0.7853981633974483f;  // 45 degrees in radians (no D3DX needed)
    float aspect = 800.0f / 600.0f;
    float zn = 1.0f, zf = 100.0f;
    float f = 1.0f / tan(fov / 2.0f);
    memset(&proj, 0, sizeof(proj));
    proj._11 = f / aspect;
    proj._22 = f;
    proj._33 = zf / (zf - zn);
    proj._34 = 1.0f;
    proj._43 = -zn * zf / (zf - zn);
    dev->SetTransform(D3DTS_PROJECTION, &proj);

    printf("[OK] Setup complete. Entering render loop.\n");
    fflush(stdout);

    MSG msg;
    ZeroMemory(&msg, sizeof(msg));
    int frame = 0;
    float angle = 0.0f;
    while (msg.message != WM_QUIT) {
        if (PeekMessageA(&msg, NULL, 0U, 0U, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        } else {
            // Build rotation matrix (Y axis + slight X tilt)
            angle += 0.02f;
            float c = cosf(angle), s = sinf(angle);
            float c2 = cosf(angle * 0.5f), s2 = sinf(angle * 0.5f);
            D3DMATRIX world = {
                c,        0,   -s,      0,
                s*s2,     c2,  c*s2,    0,
                s*c2,    -s2,  c*c2,    0,
                0,        0,   0,       1
            };
            dev->SetTransform(D3DTS_WORLD, &world);

            // View matrix (camera at z = -6 looking at origin)
            D3DMATRIX view = {
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 6, 1
            };
            dev->SetTransform(D3DTS_VIEW, &view);

            dev->Clear(0, NULL, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER,
                       D3DCOLOR_XRGB(20, 20, 50), 1.0f, 0);

            dev->BeginScene();
            dev->SetStreamSource(0, vb, 0, sizeof(Vertex));
            dev->SetIndices(ib);
            dev->SetFVF(FVF);
            dev->SetTexture(0, tex);
            dev->DrawIndexedPrimitive(D3DPT_TRIANGLELIST, 0, 0, 8, 0, 12);
            dev->EndScene();

            dev->Present(NULL, NULL, NULL, NULL);

            frame++;
            if (frame == 1) {
                printf("[INFO] First frame rendered. Screenshot ready.\n");
                fflush(stdout);
            }
            Sleep(16);  // ~60fps
        }
    }

    printf("[INFO] Total frames rendered: %d\n", frame);
    if (tex) tex->Release();
    if (ib) ib->Release();
    if (vb) vb->Release();
    if (dev) dev->Release();
    if (d3d) d3d->Release();
    UnregisterClassA("DX9Cube", hInst);
    return 0;
}
