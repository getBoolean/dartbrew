# Build products belong on the Linux filesystem in an explicitly private path.
SDK ?=
BUILD ?=
VM_BUILD ?=
CXX ?= g++
HOST_FLAGS = -std=c++20 -Wall -Wextra -Werror -pthread -Isource
SOURCES = source/embedder.cc source/lifecycle.cc source/timer_worker.cc source/report.cc source/link.cc source/unsupported.cc source/keyboard.cc source/storage.cc

.PHONY: host-test host-vm check-build native-objects
check-build:
	@test -n "$(BUILD)" && test -n "$(SDK)"
	@mkdir -p "$(BUILD)"

host-test: check-build
	$(CXX) $(HOST_FLAGS) test/timer_worker_test.cc source/timer_worker.cc -o "$(BUILD)/timer_worker_test"
	timeout 20 "$(BUILD)/timer_worker_test"
	$(CXX) $(HOST_FLAGS) test/lifecycle_test.cc source/lifecycle.cc -o "$(BUILD)/lifecycle_test"
	timeout 20 "$(BUILD)/lifecycle_test"
	$(CXX) $(HOST_FLAGS) -I"$(SDK)/runtime/include" -c source/embedder.cc -o "$(BUILD)/embedder.o"
	$(CXX) $(HOST_FLAGS) -I"$(SDK)/runtime/include" -c source/unsupported.cc -o "$(BUILD)/unsupported.o"
	$(CXX) $(HOST_FLAGS) test/report_test.cc source/report.cc -o "$(BUILD)/report_test"
	timeout 20 "$(BUILD)/report_test"
	$(CXX) $(HOST_FLAGS) test/storage_test.cc source/storage.cc -o "$(BUILD)/storage_test"
	timeout 20 "$(BUILD)/storage_test"
	$(CXX) $(HOST_FLAGS) test/keyboard_test.cc source/keyboard.cc -o "$(BUILD)/keyboard_test"
	timeout 20 "$(BUILD)/keyboard_test"
	# The dart:io event handler's poll set from the SDK checkout (patch 0035).
	$(CXX) $(HOST_FLAGS) -DDART_CTR_POLL_HOST_TEST -I"$(SDK)/runtime" test/eventhandler_host_test.cc \
	  "$(SDK)/runtime/bin/eventhandler_ctr_poll.cc" -o "$(BUILD)/eventhandler_host_test"
	timeout 20 "$(BUILD)/eventhandler_host_test"
	# The dart:io path model from the SDK checkout (patch 0036).
	$(CXX) $(HOST_FLAGS) -DDART_CTR_PATH_HOST_TEST -I"$(SDK)/runtime" test/path_host_test.cc 	  "$(SDK)/runtime/bin/path_ctr.cc" -o "$(BUILD)/path_host_test"
	timeout 20 "$(BUILD)/path_host_test"
	python3 -m unittest discover -s test -p 'test_*.py' -v

# Link the integration driver with the SDK's successfully linked host VM.
# VM_BUILD must already contain libdart_jit.so; this does not rebuild it.
host-vm: check-build
	@test -n "$(VM_BUILD)"
	@test -f "$(VM_BUILD)/libdart_jit.so"
	$(CXX) -std=c++20 -Wall -Wextra -Werror -pthread -rdynamic \
	  -I"$(abspath source)" -I"$(SDK)/runtime/include" \
	  "$(abspath test/host_vm_test.cc)" $(foreach src,$(SOURCES),"$(abspath $(src))") \
	  -L"$(VM_BUILD)" -Wl,-rpath,"$(VM_BUILD)" -ldart_jit -o "$(BUILD)/host_vm_test"

# Caller supplies the exact native GN defines/includes and the packaging objects.
# No distro ARM compiler fallback and no unqualified final link is performed here.
native-objects: check-build
	python3 ../../toolchain/native_linux.py check
	@for src in $(SOURCES) source/main.cc; do \
	  /opt/devkitpro/devkitARM/bin/arm-none-eabi-g++ $(NATIVE_FLAGS) -std=c++20 -D__3DS__ \
	    -Wall -Wextra -Werror -I"$(SDK)/runtime" -I"$(SDK)/runtime/include" -Isource \
	    -c $$src -o "$(BUILD)/$$(basename $$src .cc).o" || exit $$?; \
	done
