SHELL := /bin/sh

.PHONY: test
test:
	swift test

.PHONY: test-ios-simulator
test-ios-simulator:
	DESTINATION="$${IOS_SIMULATOR_DESTINATION:-$$(sh ./scripts/resolve-ios-simulator-destination.sh)}"; \
	echo "Using iOS simulator destination: $$DESTINATION"; \
	xcodebuild test -scheme debugbundle-swift-Package -destination "$$DESTINATION"

.PHONY: build
build:
	swift build

.PHONY: clean
clean:
	swift package clean