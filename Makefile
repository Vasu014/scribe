.PHONY: project build test clean

project:
	xcodegen generate

build: project
	set -o pipefail && xcodebuild -project Scribe.xcodeproj -scheme Scribe build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5

test:
	cd Packages/MeetingKitCore && swift test

clean:
	rm -rf Scribe.xcodeproj Packages/MeetingKitCore/.build
