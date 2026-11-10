// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#include <stdbool.h>
#include <stddef.h>

// Makes mimalloc on [start, start + size) the zone of malloc().
bool EmpoUseHeap(void *start, size_t size);

#define EMPO_HEAP_PAGE (16u << 10)

// Memory from the block, aligned to EMPO_HEAP_PAGE. mimalloc does not
// zero it.
void *EmpoHeapPages(size_t size);
void EmpoHeapFree(void *pointer);
