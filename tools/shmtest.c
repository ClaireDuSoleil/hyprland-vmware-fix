#define _GNU_SOURCE
// Minimal wl_shm client: proves whether a non-dmabuf client can map and render.
#include <wayland-client.h>
#include "xdg-shell.h"
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

static struct wl_compositor *comp; static struct wl_shm *shm;
static struct xdg_wm_base *wmbase; static int configured = 0, W = 400, H = 300;

static void wmping(void *d, struct xdg_wm_base *b, uint32_t s){ xdg_wm_base_pong(b, s); }
static const struct xdg_wm_base_listener wmlist = { wmping };

static void reg(void *d, struct wl_registry *r, uint32_t id, const char *iface, uint32_t v){
    if (!strcmp(iface,"wl_compositor")) comp = wl_registry_bind(r,id,&wl_compositor_interface,4);
    else if (!strcmp(iface,"wl_shm"))   shm  = wl_registry_bind(r,id,&wl_shm_interface,1);
    else if (!strcmp(iface,"xdg_wm_base")){ wmbase = wl_registry_bind(r,id,&xdg_wm_base_interface,1);
        xdg_wm_base_add_listener(wmbase,&wmlist,NULL); }
}
static void regrem(void *d, struct wl_registry *r, uint32_t id){}
static const struct wl_registry_listener reglist = { reg, regrem };

static void surfconf(void *d, struct xdg_surface *s, uint32_t serial){
    xdg_surface_ack_configure(s, serial); configured = 1;
}
static const struct xdg_surface_listener slist = { surfconf };
static void topconf(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *a){}
static void topclose(void *d, struct xdg_toplevel *t){}
static const struct xdg_toplevel_listener tlist = { topconf, topclose };

int main(void){
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy){ printf("FAIL: cannot connect\n"); return 1; }
    struct wl_registry *r = wl_display_get_registry(dpy);
    wl_registry_add_listener(r,&reglist,NULL);
    wl_display_roundtrip(dpy);
    if (!comp||!shm||!wmbase){ printf("FAIL: missing globals comp=%p shm=%p wm=%p\n",(void*)comp,(void*)shm,(void*)wmbase); return 1; }
    printf("OK: bound wl_compositor, wl_shm, xdg_wm_base\n");

    struct wl_surface *surf = wl_compositor_create_surface(comp);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wmbase, surf);
    xdg_surface_add_listener(xs,&slist,NULL);
    struct xdg_toplevel *tl = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(tl,&tlist,NULL);
    xdg_toplevel_set_title(tl,"shmtest");
    wl_surface_commit(surf);
    wl_display_roundtrip(dpy);
    if (!configured){ printf("FAIL: never configured\n"); return 1; }
    printf("OK: xdg_surface configured\n");

    int stride = W*4, size = stride*H;
    char name[] = "/shmtest-XXXXXX"; 
    int fd = memfd_create("shmtest", 0);
    if (fd < 0){ printf("FAIL: memfd\n"); return 1; }
    if (ftruncate(fd,size) < 0){ printf("FAIL: ftruncate\n"); return 1; }
    uint32_t *px = mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if (px == MAP_FAILED){ printf("FAIL: mmap\n"); return 1; }
    for (int i=0;i<W*H;i++) px[i] = 0xFFFF00FF; // opaque magenta

    struct wl_shm_pool *pool = wl_shm_create_pool(shm,fd,size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool,0,W,H,stride,WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    printf("OK: created wl_shm buffer %dx%d\n",W,H);

    wl_surface_attach(surf,buf,0,0);
    wl_surface_damage_buffer(surf,0,0,W,H);
    wl_surface_commit(surf);
    if (wl_display_roundtrip(dpy) < 0){ printf("FAIL: protocol error after attach/commit\n"); return 2; }
    printf("OK: attached + committed, no protocol error\n");
    printf("RESULT: SHM CLIENT MAPPED SUCCESSFULLY (magenta window should be visible)\n");
    fflush(stdout);
    for (int i=0;i<900;i++){ if (wl_display_roundtrip(dpy) < 0){ printf("FAIL: died after %d\n",i); return 2; } sleep(1); }
    return 0;
}
