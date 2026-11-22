# Build products belong on the Linux filesystem in an explicitly private path.
SDK ?=
BUILD ?= $(or $(TMPDIR),/tmp)/dartbrew-ctr-host-test
VM_BUILD ?=
RUNTIME ?=
CXX ?= g++
OBJDUMP ?= /opt/devkitpro/devkitARM/bin/arm-none-eabi-objdump
TEST_TIMEOUT = timeout 20
HOST_FLAGS = -std=c++20 -Wall -Wextra -Werror -pthread -Isource
# Journal vectors shared with the host's verdict tests.
VERDICT_VECTORS = ../../packages/dartbrew/test/data/verdict_vectors.json
SOURCES = source/embedder.cc source/lifecycle.cc source/timer_worker.cc source/report.cc source/link.cc source/unsupported.cc source/keyboard.cc source/stdin_source.cc source/storage.cc
# Host stand-ins for libctru that the SDK host tests compile SDK sources against.
SDK_FIXTURES = ../../toolchain/test
SDK_VM_FLAGS = -std=c++20 -D__3DS__ -DDEBUG
# Instructions the ARM11 cannot execute or that the runtime must not emit.
BANNED_MNEMONICS = sdiv|udiv|movw|movt|dmb|dsb|isb
# The ARM11 data memory barrier: mcr p15, 0, Rt, c7, c10, 5.
CP15_DMB = mcr[[:space:]]+15,[[:space:]]*0,[[:space:]]*r[0-9]+,[[:space:]]*cr7,[[:space:]]*cr10,[[:space:]]*\{5\}

.PHONY: host-test sdk-host-test barrier-check host-vm build-dir check-sdk
build-dir:
	@mkdir -p "$(BUILD)"

check-sdk:
	@test -n "$(SDK)" || { echo "SDK must name the patched Dart SDK checkout" >&2; exit 1; }

# Launcher tests that need only a host C++ compiler.
host-test: build-dir
	$(CXX) $(HOST_FLAGS) test/timer_worker_test.cc source/timer_worker.cc -o "$(BUILD)/timer_worker_test"
	$(TEST_TIMEOUT) "$(BUILD)/timer_worker_test"
	$(CXX) $(HOST_FLAGS) test/lifecycle_test.cc source/lifecycle.cc -o "$(BUILD)/lifecycle_test"
	$(TEST_TIMEOUT) "$(BUILD)/lifecycle_test"
	$(CXX) $(HOST_FLAGS) test/report_test.cc source/report.cc -o "$(BUILD)/report_test"
	$(TEST_TIMEOUT) "$(BUILD)/report_test" "$(VERDICT_VECTORS)"
	$(CXX) $(HOST_FLAGS) test/storage_test.cc source/storage.cc -o "$(BUILD)/storage_test"
	$(TEST_TIMEOUT) "$(BUILD)/storage_test"
	$(CXX) $(HOST_FLAGS) test/keyboard_test.cc source/keyboard.cc -o "$(BUILD)/keyboard_test"
	$(TEST_TIMEOUT) "$(BUILD)/keyboard_test"
	$(CXX) $(HOST_FLAGS) test/stdin_source_test.cc source/stdin_source.cc source/keyboard.cc -o "$(BUILD)/stdin_source_test"
	$(TEST_TIMEOUT) "$(BUILD)/stdin_source_test"
	$(CXX) $(HOST_FLAGS) -Itest/input_host test/input_test.cc -o "$(BUILD)/input_test"
	$(TEST_TIMEOUT) "$(BUILD)/input_test"

# Host tests of launcher and SDK sources that need the patched SDK checkout.
sdk-host-test: check-sdk build-dir
	$(CXX) $(HOST_FLAGS) -I"$(SDK)/runtime/include" -c source/embedder.cc -o "$(BUILD)/embedder.o"
	$(CXX) $(HOST_FLAGS) -I"$(SDK)/runtime/include" -c source/unsupported.cc -o "$(BUILD)/unsupported.o"
	# The dart:io event handler's poll set (patch 0035).
	$(CXX) $(HOST_FLAGS) -DDART_CTR_POLL_HOST_TEST -I"$(SDK)/runtime" test/eventhandler_host_test.cc \
	  "$(SDK)/runtime/bin/eventhandler_ctr_poll.cc" -o "$(BUILD)/eventhandler_host_test"
	$(TEST_TIMEOUT) "$(BUILD)/eventhandler_host_test"
	# The dart:io path model (patch 0036).
	$(CXX) $(HOST_FLAGS) -DDART_CTR_PATH_HOST_TEST -I"$(SDK)/runtime" test/path_host_test.cc \
	  "$(SDK)/runtime/bin/path_ctr.cc" -o "$(BUILD)/path_host_test"
	$(TEST_TIMEOUT) "$(BUILD)/path_host_test"
	# Synchronization and OS adapters.
	$(CXX) $(SDK_VM_FLAGS) -pthread -I$(SDK_FIXTURES)/ctr_sync_host -I"$(SDK)/runtime" \
	  "$(SDK)/runtime/platform/synchronization_ctr.cc" $(SDK_FIXTURES)/ctr_sync_host/test.cc \
	  -o "$(BUILD)/sync_test"
	$(TEST_TIMEOUT) "$(BUILD)/sync_test"
	$(CXX) $(SDK_VM_FLAGS) -pthread -DDART_DISABLE_TIMELINE -ffunction-sections -fdata-sections \
	  -I$(SDK_FIXTURES)/ctr_sync_host -I"$(SDK)/runtime" -I"$(SDK)" \
	  "$(SDK)/runtime/vm/os_ctr.cc" "$(SDK)/runtime/platform/synchronization_ctr.cc" \
	  $(SDK_FIXTURES)/ctr_sync_host/os_test.cc -Wl,--gc-sections -Wl,--wrap=clock_gettime \
	  -o "$(BUILD)/os_test"
	$(TEST_TIMEOUT) "$(BUILD)/os_test"
	# Thread ownership; an unsupported TLS alignment must abort at the TLS boundary.
	$(CXX) $(SDK_VM_FLAGS) -pthread -DDART_DISABLE_TIMELINE -no-pie \
	  -I$(SDK_FIXTURES)/ctr_thread_host -I$(SDK_FIXTURES)/ctr_sync_host -I"$(SDK)/runtime" \
	  "$(SDK)/runtime/vm/os_thread_ctr.cc" "$(SDK)/runtime/platform/synchronization_ctr.cc" \
	  $(SDK_FIXTURES)/ctr_thread_host/test.cc -o "$(BUILD)/thread_test"
	$(TEST_TIMEOUT) "$(BUILD)/thread_test"
	$(TEST_TIMEOUT) "$(BUILD)/thread_test" creation-failure
	$(CXX) $(SDK_VM_FLAGS) -pthread -DDART_DISABLE_TIMELINE -no-pie -DCTR_TEST_TLS_ALIGNMENT=16 \
	  -I$(SDK_FIXTURES)/ctr_thread_host -I$(SDK_FIXTURES)/ctr_sync_host -I"$(SDK)/runtime" \
	  "$(SDK)/runtime/vm/os_thread_ctr.cc" "$(SDK)/runtime/platform/synchronization_ctr.cc" \
	  $(SDK_FIXTURES)/ctr_thread_host/test.cc -o "$(BUILD)/thread_tls_alignment_test"
	$(TEST_TIMEOUT) "$(BUILD)/thread_tls_alignment_test" 2> "$(BUILD)/thread_tls_alignment_test.stderr"; \
	  status=$$?; test $$status -eq 134 && grep -q __tdata_align "$(BUILD)/thread_tls_alignment_test.stderr" \
	  || { echo "unsupported TLS alignment was not rejected at the TLS boundary (exit $$status)" >&2; exit 1; }
	# Virtual memory and cache adapters.
	$(CXX) $(SDK_VM_FLAGS) -I$(SDK_FIXTURES)/ctr_memory_host -I$(SDK_FIXTURES)/ctr_sync_host \
	  -I"$(SDK)/runtime" \
	  "$(SDK)/runtime/vm/virtual_memory.cc" "$(SDK)/runtime/vm/virtual_memory_ctr.cc" \
	  "$(SDK)/runtime/vm/cpu_cache_ctr.cc" $(SDK_FIXTURES)/ctr_memory_host/test.cc \
	  -Wl,--wrap=memalign -Wl,--wrap=free -o "$(BUILD)/memory_test"
	$(TEST_TIMEOUT) "$(BUILD)/memory_test"
	# Native symbol resolver, under ASan and UBSan.
	$(CXX) -std=c++20 -fsanitize=address,undefined -fno-omit-frame-pointer -no-pie \
	  -I$(SDK_FIXTURES)/ctr_symbols_host -I"$(SDK)/runtime" \
	  "$(SDK)/runtime/vm/native_symbol_ctr.cc" $(SDK_FIXTURES)/ctr_symbols_host/test.cc \
	  $(SDK_FIXTURES)/ctr_symbols_host/image.S \
	  -D_start=ctr_test_image_start -D__bss_end__=ctr_test_image_end -o "$(BUILD)/symbols_test"
	$(TEST_TIMEOUT) "$(BUILD)/symbols_test"
	# Basename, built with the checkout's clang.
	"$(SDK)/buildtools/linux-x64/clang/bin/clang++" -I$(SDK_FIXTURES)/ctr_sync_host \
	  -std=c++20 -O2 -DNDEBUG -D__3DS__ -ffunction-sections -fdata-sections \
	  -I"$(SDK)/runtime" -I"$(SDK)" -Wall -Wextra -Werror -Wno-unused-parameter \
	  $(SDK_FIXTURES)/ctr_link_host/basename_test.cc \
	  "$(SDK)/runtime/platform/utils.cc" "$(SDK)/runtime/platform/utils_ctr.cc" \
	  -Wl,--gc-sections -o "$(BUILD)/basename_test"
	$(TEST_TIMEOUT) "$(BUILD)/basename_test"

# Fails when RUNTIME, a CTR runtime archive, contains an instruction the ARM11
# cannot execute or lacks the CP15 data memory barrier.
barrier-check:
	@test -f "$(RUNTIME)" || { echo "RUNTIME must name a runtime archive" >&2; exit 1; }
	@disassembly=$$(mktemp) && trap 'rm -f "$$disassembly"' EXIT && \
	  "$(OBJDUMP)" -d "$(RUNTIME)" > "$$disassembly" && \
	  awk -F '\t' '$$3 ~ /^($(BANNED_MNEMONICS))/ { print "banned instruction " $$3 ": " $$0; found = 1 } \
	    END { exit found }' "$$disassembly" >&2 && \
	  { grep -Eq '$(CP15_DMB)' "$$disassembly" || \
	    { echo "CP15 data memory barrier absent from $(RUNTIME)" >&2; exit 1; }; } && \
	  echo "PASS barrier-check $(RUNTIME)"

# Link the integration driver with the SDK's successfully linked host VM.
# VM_BUILD must already contain libdart_jit.so; this does not rebuild it.
host-vm: check-sdk build-dir
	@test -n "$(VM_BUILD)"
	@test -f "$(VM_BUILD)/libdart_jit.so"
	$(CXX) -std=c++20 -Wall -Wextra -Werror -pthread -rdynamic \
	  -I"$(abspath source)" -I"$(SDK)/runtime/include" \
	  "$(abspath test/host_vm_test.cc)" $(foreach src,$(SOURCES),"$(abspath $(src))") \
	  -L"$(VM_BUILD)" -Wl,-rpath,"$(VM_BUILD)" -ldart_jit -o "$(BUILD)/host_vm_test"
