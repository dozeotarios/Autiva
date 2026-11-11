# SBTouch / Autiva build.
#
# Two very different builds live here on purpose:
#
#   make test    host build of the portable core (Linux, no device, no ObjC).
#                Protocol regressions are caught here in milliseconds.
#   make dylib   device build of the injected dylib, compiled ON the phone with
#                its own Procursus clang-16 (see build_device.sh).
#   make cli     the `sbtctl` socket client (also built on the phone).
#   make install deploy dylib + cli, then respring.
#
# Device constraints measured 2026-11-11:
#   * the phone's libc++ has no floating-point std::to_chars/from_chars;
#   * a binary executed from /tmp is SIGKILLed (rc=137) — it must live under
#     /var/jb, and be ldid-signed.
#
# PHONE defaults to the production device; override with `make PHONE=... dylib`.
PHONE ?= root@10.0.0.2
SSH   ?= ssh -o ConnectTimeout=8
SCP   ?= scp -o ConnectTimeout=8 -q
REMOTE_DIR ?= /tmp/sbtouch-build

CXX_HOST ?= g++
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti
CORE_SRC := src/core/json.cpp src/core/protocol.cpp src/core/rng.cpp src/core/profile.cpp \
            src/core/plan.cpp src/core/record.cpp
CORE_HDR := src/core/json.hpp src/core/protocol.hpp src/core/rng.hpp src/core/profile.hpp \
            src/core/plan.hpp src/core/record.hpp

# Short build stamp baked into `version` so a deployed dylib is always
# identifiable (the previous build drifted a whole version ahead of its source).
BUILD := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

.PHONY: all test dylib cli push-src install clean

all: test dylib cli

# ── host ────────────────────────────────────────────────────────────────────
test: build/test_core
	./build/test_core

build/test_core: tests/test_core.cpp $(CORE_SRC) $(CORE_HDR)
	mkdir -p build
	$(CXX_HOST) $(CXXFLAGS) -Isrc/core -o $@ tests/test_core.cpp $(CORE_SRC)

clean:
	rm -rf build

# ── device ──────────────────────────────────────────────────────────────────
push-src:
	$(SSH) $(PHONE) 'mkdir -p $(REMOTE_DIR)'
	$(SCP) -r src deploy build_device.sh Makefile $(PHONE):$(REMOTE_DIR)/

dylib: push-src
	$(SSH) $(PHONE) 'cd $(REMOTE_DIR) && AUTIVA_BUILD=$(BUILD) /var/jb/bin/bash build_device.sh dylib'

cli: push-src
	$(SSH) $(PHONE) 'cd $(REMOTE_DIR) && AUTIVA_BUILD=$(BUILD) /var/jb/bin/bash build_device.sh cli'

# Backup of the deployed binary is kept on the phone: /tmp/SpringBoardTouch.v8.dylib
install: dylib cli
	$(SSH) $(PHONE) 'set -e; \
	  D=/var/jb/usr/lib/TweakInject/SpringBoardTouch.dylib; \
	  [ -f $$D ] && cp -f $$D /tmp/SpringBoardTouch.v8.dylib; \
	  cp -f /tmp/SpringBoardTouch.dylib.new $$D; \
	  cp -f $(REMOTE_DIR)/sbtctl /var/jb/usr/bin/sbtctl; \
	  chmod 755 $$D /var/jb/usr/bin/sbtctl; \
	  echo installed; ls -l $$D /var/jb/usr/bin/sbtctl'
