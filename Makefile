SWIFTPM_CACHE_PATH ?= .swiftpm-cache
SWIFTPM_CONFIG_PATH ?= .swiftpm-config
SWIFTPM_SECURITY_PATH ?= .swiftpm-security

SWIFTPM_PATH_FLAGS = \
	--cache-path $(SWIFTPM_CACHE_PATH) \
	--config-path $(SWIFTPM_CONFIG_PATH) \
	--security-path $(SWIFTPM_SECURITY_PATH)

SWIFT_BUILD_FLAGS ?=

.PHONY: build build-debug build-release bundle-menubar clean smoke smoke-mps

build: build-release

build-debug:
	swift build $(SWIFTPM_PATH_FLAGS) $(SWIFT_BUILD_FLAGS)

build-release:
	swift build -c release $(SWIFTPM_PATH_FLAGS) $(SWIFT_BUILD_FLAGS)

bundle-menubar:
	./scripts/package-menubar-app.sh

clean:
	rm -rf .build $(SWIFTPM_CACHE_PATH) $(SWIFTPM_CONFIG_PATH) $(SWIFTPM_SECURITY_PATH)

smoke: build-release
	./.build/release/gobx --help >/dev/null
	./.build/release/gobx selftest
	./.build/release/gobx score 1 --backend cpu >/dev/null
	./.build/release/gobx explore --count 2000 --report-every 1 --no-ui --no-submit

smoke-mps: build-release
	./.build/release/gobx score 1 --backend mps --batch 64
	./.build/release/gobx explore --count 5000 --report-every 1 --no-ui --gpu-profile heater --no-submit
