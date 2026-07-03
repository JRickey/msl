#ifndef MSL_SYS_H
#define MSL_SYS_H

#include <sys/clonefile.h>
#include <sys/file.h>

/* Wrapper around flock(2): the Darwin module shadows the C function with the
 * struct of the same name, so Swift cannot call it directly. */
static inline int msl_flock(int fd, int op) {
    return flock(fd, op);
}

/* clonefile(2): a COW, sparse-preserving copy on APFS. Returns 0 on success,
 * -1 with errno set (EXDEV across filesystems -> caller falls back to a copy). */
static inline int msl_clonefile(const char *src, const char *dst) {
    return clonefile(src, dst, 0);
}

#endif /* MSL_SYS_H */
