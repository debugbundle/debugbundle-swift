SHELL := /bin/sh
SWIFT_TEST_ARGS ?=
XCODE_TEST_ARGS ?=
RECEIPT_FILES ?=

.PHONY: test
test: coverage

.PHONY: test-filtered
test-filtered:
	test -n "$(FILTER)"
	swift test $(SWIFT_TEST_ARGS) --filter "$(FILTER)"

.PHONY: evidence-performance
evidence-performance:
	swift test --configuration release $(SWIFT_TEST_ARGS) list
	@set -eu; for lane in off-empty off-full on-empty on-full; do \
	  EVIDENCE_PERFORMANCE_CASE=$$lane swift test --skip-build --configuration release $(SWIFT_TEST_ARGS) --filter DebugBundleEvidencePerformanceTests; \
	done

.PHONY: coverage
coverage:
	swift test $(SWIFT_TEST_ARGS) --enable-code-coverage -Xcc -fprofile-instr-generate -Xcc -fcoverage-mapping
	$(MAKE) coverage-check

.PHONY: coverage-check
coverage-check:
	COVERAGE_PATH="$$(swift test --show-codecov-path)"; \
	python3 ./scripts/check-coverage.py "$$COVERAGE_PATH"

.PHONY: smoke-spm
smoke-spm:
	./scripts/smoke-spm.sh

.PHONY: smoke-spm-published smoke-cocoapods-git
smoke-spm-published:
	sh scripts/smoke-spm.sh --published "$(VERSION)"

smoke-cocoapods-git:
	sh scripts/smoke-cocoapods.sh --git "$(VERSION)"

.PHONY: evidence-manifest
evidence-manifest:
	python3 scripts/evidence-artifact-manifest.py $(foreach receipt,$(RECEIPT_FILES),--receipt "$(receipt)")

.PHONY: smoke-source-artifact
smoke-source-artifact: evidence-manifest
	sh scripts/smoke-source-artifact.sh

.PHONY: smoke-cocoapods
smoke-cocoapods:
	sh ./scripts/smoke-cocoapods.sh

.PHONY: smoke-cocoapods-published
smoke-cocoapods-published:
	sh ./scripts/smoke-cocoapods.sh --published "$(VERSION)"

.PHONY: test-ios-simulator
# Avoid simulator cloning while the delivery and deadline tests exercise one process.
test-ios-simulator:
	DESTINATION="$${IOS_SIMULATOR_DESTINATION:-$$(sh ./scripts/resolve-ios-simulator-destination.sh)}"; \
	echo "Using iOS simulator destination: $$DESTINATION"; \
	xcodebuild test -scheme debugbundle-swift-Package -destination "$$DESTINATION" -parallel-testing-enabled NO $(XCODE_TEST_ARGS)

.PHONY: build-ios-15
build-ios-15:
	xcodebuild build -quiet -scheme debugbundle-swift-Package -destination 'generic/platform=iOS Simulator' IPHONEOS_DEPLOYMENT_TARGET=15.0

.PHONY: build
build:
	swift build

.PHONY: pod-lint
pod-lint:
	pod spec lint DebugBundle.podspec --quick --allow-warnings

.PHONY: pod-publish
pod-publish:
	pod trunk push DebugBundle.podspec --allow-warnings --synchronous

.PHONY: clean
clean:
	swift package clean
