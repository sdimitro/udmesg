// SPDX-License-Identifier: GPL-2.0-or-later

#include <libkdumpfile/kdumpfile.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

void *udk_open(unsigned nfds, const int *fds)
{
	kdump_ctx_t *ctx = kdump_new();
	if (!ctx)
		return NULL;
	if (kdump_open_fdset(ctx, nfds, fds) != KDUMP_OK ||
	    kdump_set_string_attr(ctx, KDUMP_ATTR_OSTYPE, "linux") != KDUMP_OK) {
		kdump_free(ctx);
		return NULL;
	}
	return ctx;
}

void udk_close(void *ctx)
{
	kdump_free(ctx);
}

int udk_read(void *ctx, uint64_t addr, void *dest, size_t size,
	     uint64_t image_offset, uint64_t linear_offset, int has_linear)
{
	size_t requested = size;
	if (kdump_read(ctx, KDUMP_KVADDR, addr, dest, &size) == KDUMP_OK)
		return 1;
	if (image_offset) {
		size = requested;
		if (kdump_read(ctx, KDUMP_KPHYSADDR, addr - image_offset,
			       dest, &size) == KDUMP_OK)
			return 1;
	}
	if (has_linear) {
		size = requested;
		if (kdump_read(ctx, KDUMP_KPHYSADDR, addr + linear_offset,
			       dest, &size) == KDUMP_OK)
			return 1;
	}
	return 0;
}

int udk_vmcoreinfo(void *ctx, char **raw)
{
	return kdump_vmcoreinfo_raw(ctx, raw) == KDUMP_OK;
}

int udk_target(void *ctx, unsigned *word_size, unsigned *big_endian,
	       unsigned *aarch64)
{
	kdump_attr_t attr;

	if (kdump_get_attr(ctx, KDUMP_ATTR_PTR_SIZE, &attr) != KDUMP_OK ||
	    attr.type != KDUMP_NUMBER ||
	    (attr.val.number != 4 && attr.val.number != 8))
		return 0;
	*word_size = attr.val.number;
	if (kdump_get_attr(ctx, KDUMP_ATTR_BYTE_ORDER, &attr) != KDUMP_OK ||
	    attr.type != KDUMP_NUMBER ||
	    (attr.val.number != KDUMP_BIG_ENDIAN &&
	     attr.val.number != KDUMP_LITTLE_ENDIAN))
		return 0;
	*big_endian = attr.val.number == KDUMP_BIG_ENDIAN;
	*aarch64 = kdump_get_attr(ctx, KDUMP_ATTR_ARCH_NAME, &attr) == KDUMP_OK &&
		   attr.type == KDUMP_STRING &&
		   strcmp(attr.val.string, KDUMP_ARCH_AARCH64) == 0;
	return 1;
}

const char *udk_error(void *ctx)
{
	return kdump_get_err(ctx);
}

void udk_release(char *raw)
{
	free(raw);
}
