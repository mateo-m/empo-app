#include "AppMemoryHeap.h"

#include <mach/mach.h>
#include <malloc/malloc.h>
#include <string.h>

#include "mimalloc.h"

static malloc_zone_t *gSystem;

static bool systemOwns(const void *p) {
    return gSystem->size(gSystem, p) != 0;
}

// While the system zone is out of the list for the reorder, free()
// finds no zone for its blocks and aborts. So this zone claims them too.
static size_t zoneSize(malloc_zone_t *zone, const void *p) {
    if (mi_is_in_heap_region(p)) return mi_usable_size(p);
    return gSystem->size(gSystem, p);
}

static void *zoneMalloc(malloc_zone_t *zone, size_t size) { return mi_malloc(size); }
static void *zoneCalloc(malloc_zone_t *zone, size_t count, size_t size) { return mi_calloc(count, size); }
static void *zoneValloc(malloc_zone_t *zone, size_t size) { return mi_malloc_aligned(size, vm_page_size); }
static void *zoneMemalign(malloc_zone_t *zone, size_t alignment, size_t size) { return mi_malloc_aligned(size, alignment); }

// A block from before the switch belongs to the system zone.
static void zoneFree(malloc_zone_t *zone, void *p) {
    if (mi_is_in_heap_region(p)) {
        mi_free(p);
    } else if (systemOwns(p)) {
        gSystem->free(gSystem, p);
    }
}

static void *zoneRealloc(malloc_zone_t *zone, void *p, size_t size) {
    if (p == NULL || mi_is_in_heap_region(p)) return mi_realloc(p, size);
    size_t old = gSystem->size(gSystem, p);
    void *moved = mi_malloc(size);
    if (moved != NULL) {
        memcpy(moved, p, old < size ? old : size);
        gSystem->free(gSystem, p);
    }
    return moved;
}

static void zoneDestroy(malloc_zone_t *zone) {}

static unsigned zoneBatchMalloc(malloc_zone_t *zone, size_t size, void **ps, unsigned count) {
    unsigned i = 0;
    for (; i < count && (ps[i] = mi_malloc(size)) != NULL; i++) {}
    return i;
}

static void zoneBatchFree(malloc_zone_t *zone, void **ps, unsigned count) {
    for (unsigned i = 0; i < count; i++) zoneFree(zone, ps[i]);
}

static size_t zonePressureRelief(malloc_zone_t *zone, size_t goal) {
    mi_collect(false);
    return 0;
}

static void zoneFreeDefiniteSize(malloc_zone_t *zone, void *p, size_t size) { zoneFree(zone, p); }
// free() can look a block up through this, so it claims the system
// zone's blocks too, as zoneSize does.
static boolean_t zoneClaimedAddress(malloc_zone_t *zone, void *p) {
    return mi_is_in_heap_region(p) || systemOwns(p);
}

static kern_return_t introEnumerator(task_t task, void *p, unsigned mask, vm_address_t zone, memory_reader_t reader,
                                     vm_range_recorder_t recorder) {
    return KERN_SUCCESS;
}
static size_t introGoodSize(malloc_zone_t *zone, size_t size) { return mi_good_size(size); }
static boolean_t introCheck(malloc_zone_t *zone) { return true; }
static void introPrint(malloc_zone_t *zone, boolean_t verbose) {}
static void introLog(malloc_zone_t *zone, void *p) {}
static void introLock(malloc_zone_t *zone) {}
static void introStatistics(malloc_zone_t *zone, malloc_statistics_t *stats) { memset(stats, 0, sizeof *stats); }
static boolean_t introLocked(malloc_zone_t *zone) { return false; }

static malloc_introspection_t gIntrospect = {
    .enumerator = introEnumerator,
    .good_size = introGoodSize,
    .check = introCheck,
    .print = introPrint,
    .log = introLog,
    .force_lock = introLock,
    .force_unlock = introLock,
    .statistics = introStatistics,
    .zone_locked = introLocked,
    // _malloc_fork_child calls it with no NULL check.
    .reinit_lock = introLock,
};

static malloc_zone_t gZone = {
    .size = zoneSize,
    .malloc = zoneMalloc,
    .calloc = zoneCalloc,
    .valloc = zoneValloc,
    .free = zoneFree,
    .realloc = zoneRealloc,
    .destroy = zoneDestroy,
    .zone_name = "empo-app-memory",
    .batch_malloc = zoneBatchMalloc,
    .batch_free = zoneBatchFree,
    .introspect = &gIntrospect,
    .version = 10,
    .memalign = zoneMemalign,
    .free_definite_size = zoneFreeDefiniteSize,
    .pressure_relief = zonePressureRelief,
    .claimed_address = zoneClaimedAddress,
};

void *EmpoHeapPages(size_t size) { return mi_malloc_aligned(size, 16u << 10); }
void EmpoHeapFree(void *pointer) { mi_free(pointer); }

bool EmpoUseHeap(void *start, size_t size) {
    // A purge would decommit pages of the app's memory entry.
    mi_option_set(mi_option_purge_delay, -1);
    // When the block is full, mimalloc takes memory of this process.
    mi_option_set(mi_option_arena_reserve, 0);
    mi_arena_id_t arena = 0;
    if (!mi_manage_os_memory_ex(start, size, true, false, false, -1, false, &arena)) return false;
    malloc_zone_t **zones = NULL;
    unsigned count = 0;
    malloc_get_all_zones(mach_task_self(), NULL, (vm_address_t **)&zones, &count);
    gSystem = zones[0];
    // malloc() uses the first zone in the list. Moving the system zone
    // to the end makes this zone the first.
    malloc_zone_register(&gZone);
    malloc_zone_unregister(gSystem);
    malloc_zone_register(gSystem);
    return true;
}
