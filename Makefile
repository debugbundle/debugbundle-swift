SHELL := /bin/sh

.PHONY: test
test: coverage

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
test-ios-simulator:
	DESTINATION="$${IOS_SIMULATOR_DESTINATION:-$$(sh ./scripts/resolve-ios-simulator-destination.sh)}"; \
	echo "Using iOS simulator destination: $$DESTINATION"; \
	xcodebuild test -scheme debugbundle-swift-Package -destination "$$DESTINATION"

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
