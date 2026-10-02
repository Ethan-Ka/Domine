# Builds the DomineDSP C sources on Linux with the Core Audio type shim and
# runs the plain C tests. Run from this directory: make test
ROOT := ../..
CC = clang
CFLAGS := -std=c11 -D_DEFAULT_SOURCE -O1 -g -Wall -Wextra -Wpedantic -Werror \
  -Wno-nullability-extension -Wno-unknown-pragmas -fsanitize=address,undefined \
  -I$(ROOT)/linux/compat -I$(ROOT)/Sources/DomineDSP/include -I$(ROOT)/Sources/DomineDSP
LDLIBS := -lm -fsanitize=address,undefined
DSP := $(wildcard $(ROOT)/Sources/DomineDSP/*.c)
TESTS := $(patsubst %.c,%,$(wildcard test_*.c))

all: $(TESTS)
test_%: test_%.c $(DSP) check.h
	$(CC) $(CFLAGS) $< $(DSP) -o $@ $(LDLIBS)
test: all
	@set -e; for t in $(TESTS); do echo "== $$t"; ./$$t; done
clean:
	rm -f $(TESTS)
.PHONY: all test clean
