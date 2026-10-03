# Builds the DomineDSP C sources on Linux with the Core Audio type shim and
# runs the plain C tests. Run from this directory: make test
ROOT := ../..
CC = clang
LINK ?= gcc
CFLAGS := -std=c11 -D_DEFAULT_SOURCE -O1 -g -Wall -Wextra -Wpedantic -Werror \
  -Wno-nullability-extension -Wno-unknown-pragmas -fsanitize=address,undefined \
  -I$(ROOT)/linux/compat -I$(ROOT)/Sources/DomineDSP/include -I$(ROOT)/Sources/DomineDSP
LDLIBS := -lm -fsanitize=address,undefined
DSP := $(wildcard $(ROOT)/Sources/DomineDSP/*.c)
TESTS := $(patsubst %.c,%,$(wildcard test_*.c))

all: $(TESTS)
# Compile with clang (the -Wno-nullability flags are clang's); link with gcc,
# whose ASan/UBSan runtimes are installed in the Linux container.
OBJDIR := obj
OBJS := $(patsubst $(ROOT)/Sources/DomineDSP/%.c,$(OBJDIR)/%.o,$(DSP))
HDRS := $(wildcard $(ROOT)/Sources/DomineDSP/include/*.h $(ROOT)/Sources/DomineDSP/*.h)
$(OBJDIR)/%.o: $(ROOT)/Sources/DomineDSP/%.c $(HDRS)
	@mkdir -p $(OBJDIR)
	$(CC) $(CFLAGS) -c $< -o $@
test_%: test_%.c $(OBJS) check.h
	$(CC) $(CFLAGS) -c $< -o $(OBJDIR)/$@.o
	$(LINK) $(OBJDIR)/$@.o $(OBJS) -o $@ $(LDLIBS)
test: all
	@set -e; for t in $(TESTS); do echo "== $$t"; ./$$t; done
clean:
	rm -rf $(TESTS) $(OBJDIR)
.PHONY: all test clean
.SECONDARY:
