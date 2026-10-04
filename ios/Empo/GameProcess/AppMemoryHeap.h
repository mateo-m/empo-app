#include <stdbool.h>
#include <stddef.h>

// Makes mimalloc on [start, start + size) the zone of malloc().
bool EmpoUseHeap(void *start, size_t size);

// Memory from the block, aligned to 16 KB. mimalloc does not zero it.
void *EmpoHeapPages(size_t size);
void EmpoHeapFree(void *pointer);
