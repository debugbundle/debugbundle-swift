SHELL := /bin/sh

.PHONY: test
test: coverage

.PHONY: test-filtered
test-filtered:
	test -n "$(FILTER)"
	swift test --filter "$(FILTER)"

.PHONY: coverage
coverage:
	swift test --enable-code-coverage
	COVERAGE_PATH="$$(swift test --show-codecov-path)"; \
	python3 ./scripts/check-coverage.py "$$COVERAGE_PATH"

.PHONY: smoke-spm
smoke-spm:
	./scripts/smoke-spm.sh

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
	xcodebuild test -scheme debugbundle-swift-Package -destination "$$DESTINATION" -parallel-testing-enabled NO

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
