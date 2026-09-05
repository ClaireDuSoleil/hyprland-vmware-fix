// Reproduces Hyprland's CLinuxDMABUFParamsResource::commence() probe and tests
// the DRM_VMW_UNREF_SURFACE fallback on this exact hardware.
#include <xf86drm.h>
#include <gbm.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>

#define DRM_VMW_UNREF_SURFACE 10
struct drmVmwSurfaceArg { int32_t sid; uint32_t handleType; };

static int closeVmwGFXHandle(int fd, uint32_t handle) {
    drmVersionPtr version = drmGetVersion(fd);
    int isVmwgfx = version && version->name &&
                   strncmp(version->name, "vmwgfx", version->name_len) == 0;
    if (version) drmFreeVersion(version);
    if (!isVmwgfx) return -1;
    struct drmVmwSurfaceArg arg = { (int32_t)handle, 0 };
    return drmCommandWrite(fd, DRM_VMW_UNREF_SURFACE, &arg, sizeof(arg));
}

int main(void) {
    const char *node = "/dev/dri/renderD128";
    int fd = open(node, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open"); return 1; }

    drmVersionPtr v = drmGetVersion(fd);
    printf("driver: %s\n", v && v->name ? v->name : "?");
    if (v) drmFreeVersion(v);

    struct gbm_device *gbm = gbm_create_device(fd);
    if (!gbm) { printf("FAIL: gbm_create_device\n"); return 1; }

    struct gbm_bo *bo = gbm_bo_create(gbm, 400, 300, GBM_FORMAT_XRGB8888, GBM_BO_USE_RENDERING);
    if (!bo) { printf("FAIL: gbm_bo_create\n"); return 1; }
    printf("gbm bo created, modifier=0x%llx\n", (unsigned long long)gbm_bo_get_modifier(bo));

    int dmabuf = gbm_bo_get_fd(bo);
    if (dmabuf < 0) { printf("FAIL: gbm_bo_get_fd\n"); return 1; }
    printf("exported dmabuf fd=%d\n", dmabuf);

    // --- this is exactly what commence() does ---
    uint32_t handle = 0;
    int r = drmPrimeFDToHandle(fd, dmabuf, &handle);
    printf("drmPrimeFDToHandle -> ret=%d handle=%u\n", r, handle);
    if (r) { printf("FAIL: import failed\n"); return 1; }

    int gemclose = drmCloseBufferHandle(fd, handle);
    printf("drmCloseBufferHandle -> ret=%d errno=%d (%s)\n",
           gemclose, gemclose ? errno : 0, gemclose ? strerror(errno) : "ok");

    if (gemclose == 0) {
        printf("\nRESULT: GEM close SUCCEEDED - this driver does not exhibit the bug.\n");
        return 0;
    }

    int vmwclose = closeVmwGFXHandle(fd, handle);
    printf("closeVmwGFXHandle  -> ret=%d errno=%d (%s)\n",
           vmwclose, vmwclose ? errno : 0, vmwclose ? strerror(errno) : "ok");

    if (vmwclose == 0)
        printf("\nRESULT: GEM close FAILED, vmwgfx unref SUCCEEDED -> PATCH IS CORRECT.\n");
    else
        printf("\nRESULT: BOTH closes failed -> patch does NOT fix it.\n");
    return vmwclose == 0 ? 0 : 2;
}
