#ifndef MSL_SYS_H
#define MSL_SYS_H

#include <sys/file.h>

/* Wrapper around flock(2): the Darwin module shadows the C function with the
 * struct of the same name, so Swift cannot call it directly. */
static inline int msl_flock(int fd, int op) {
    return flock(fd, op);
}

#endif /* MSL_SYS_H */
