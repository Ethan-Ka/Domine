# Domine for Linux. Needs libpipewire-0.3 and gtk4 development packages.
#   make            builds ./domine
#   make check      runs the headless engine self-test (no audio hardware needed)
ROOT := ..
CC ?= cc
PKGS := libpipewire-0.3 gtk4
CFLAGS += -std=gnu11 -O2 -g -Wall -Wextra -Wno-unknown-pragmas -Wno-nullability-extension \
  -Icompat -I$(ROOT)/Sources/DomineDSP/include -I$(ROOT)/Sources/DomineDSP -Isrc \
  $(shell pkg-config --cflags $(PKGS))
# GCC has no nullability qualifiers; some DSP headers use them before the
# compat header defines them away.
ifeq ($(shell $(CC) --version 2>/dev/null | grep -c clang),0)
CFLAGS += -D_Nullable= -D_Nonnull=
endif
LDLIBS += $(shell pkg-config --libs $(PKGS)) -lm -lpthread
DSP := $(wildcard $(ROOT)/Sources/DomineDSP/*.c)
ENGINE := $(wildcard src/engine*.c)
UI := $(filter-out $(ENGINE), $(wildcard src/*.c))

all: domine
domine: $(UI) $(ENGINE) $(DSP) $(wildcard src/*.h)
	$(CC) $(CFLAGS) $(UI) $(ENGINE) $(DSP) -o $@ $(LDLIBS)
selftest: tests/selftest.c $(ENGINE) $(DSP) $(wildcard src/*.h)
	$(CC) $(CFLAGS) tests/selftest.c $(ENGINE) $(DSP) -o $@ $(LDLIBS)
check: selftest
	./selftest
clean:
	rm -f domine selftest
.PHONY: all check clean
