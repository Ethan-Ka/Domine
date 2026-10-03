// Tiny test helpers for the Linux C tests.
#ifndef DOMINE_CHECK_H
#define DOMINE_CHECK_H
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
static int check_failures = 0;
#define CHECK(cond) do { if (!(cond)) { check_failures++; \
    fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CHECK_NEAR(a, b, eps) do { double _a = (a), _b = (b); if (!(fabs(_a - _b) <= (eps))) { \
    check_failures++; fprintf(stderr, "%s:%d: %s = %.9g, expected %.9g (eps %g)\n", \
    __FILE__, __LINE__, #a, _a, _b, (double)(eps)); } } while (0)
#define CHECK_DONE() do { if (check_failures) { fprintf(stderr, "%d failure(s)\n", check_failures); \
    return 1; } printf("ok\n"); return 0; } while (0)
#endif
