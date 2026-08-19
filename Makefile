.PHONY: project build test test-app clean

project:
	xcodegen generate

build: project
	set -o pipefail && xcodebuild -project Scribe.xcodeproj -scheme Scribe build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5

test:
	cd Packages/MeetingKitCore && swift test

# App-layer unit tests (Tests/ScribeAppTests). Runs headless — no window
# server, no TCC, no status item — because the target compiles App/ sources
# straight into the test bundle rather than hosting the app.
test-app: project
	set -o pipefail && xcodebuild test -project Scribe.xcodeproj -scheme Scribe \
		-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5

clean:
	rm -rf Scribe.xcodeproj Packages/MeetingKitCore/.build
