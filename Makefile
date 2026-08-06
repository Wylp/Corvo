.PHONY: gen build test run release icon clean

gen:
	xcodegen generate

# Regenerates the ten icon sizes from Design/AppIcon.png. Only needed when the
# artwork changes — the generated set is committed.
icon:
	swift Scripts/make-icon.swift Design/AppIcon.png \
		Sources/Corvo/Resources/Assets.xcassets/AppIcon.appiconset

build: gen
	xcodebuild -project Corvo.xcodeproj -scheme Corvo -configuration Debug build

test: gen
	xcodebuild test -project Corvo.xcodeproj -scheme Corvo -destination 'platform=macOS'

run: build
	open ~/Library/Developer/Xcode/DerivedData/Corvo-*/Build/Products/Debug/Corvo.app

release: gen
	rm -rf build
	xcodebuild -project Corvo.xcodeproj -scheme Corvo -configuration Release \
		-derivedDataPath build/dd build
	@# The debug entitlement makes the process readable by anything running as
	@# the same user. It shipped in v0.1.0; this fails the build rather than let
	@# it come back quietly.
	@codesign -d --entitlements - build/dd/Build/Products/Release/Corvo.app 2>&1 \
		| grep -q get-task-allow \
		&& { echo "FATAL: Release carries com.apple.security.get-task-allow"; exit 1; } \
		|| echo "entitlements: clean"
	mkdir -p build
	ditto -c -k --keepParent build/dd/Build/Products/Release/Corvo.app build/Corvo.zip
	@echo "built: build/Corvo.zip"

clean:
	rm -rf Corvo.xcodeproj build DerivedData
