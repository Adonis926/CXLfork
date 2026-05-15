CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -std=c11
STATIC_LDFLAGS ?= -static
IMAGE ?= criu-cxl-poc:local
DOCKER ?= docker

all: criu-cxl-poc

criu-cxl-poc: criu_cxl_poc.c
	$(CC) $(CFLAGS) -o $@ $<

static: criu-cxl-poc-static

criu-cxl-poc-static: criu_cxl_poc.c
	$(CC) $(CFLAGS) $(STATIC_LDFLAGS) -o $@ $<

docker-image: criu-cxl-poc-static
	$(DOCKER) build -f Dockerfile -t $(IMAGE) .

clean:
	rm -f criu-cxl-poc criu-cxl-poc-static

.PHONY: all static docker-image clean
