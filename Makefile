.PHONY: gen build test run release icon clean

# One place for every build, instead of wherever Xcode decides to put it.
# Xcode derives that location from the project's path, so each git worktree gets
# its own — and `run` used to glob across all of them and launch every copy it
# found. Five menu bar icons, five pollers, one clipboard.
DERIVED := build/dd

gen:
	xcodegen generate

# Regenerates the ten icon sizes from Design/AppIcon.png. Only needed when the
# artwork changes — the generated set is committed.
icon:
	swift Scripts/make-icon.swift Design/AppIcon.png \
		Sources/Corvo/Resources/Assets.xcassets/AppIcon.appiconset

build: gen
	xcodebuild -project Corvo.xcodeproj -scheme Corvo -configuration Debug \
		-derivedDataPath $(DERIVED) build

test: gen
	xcodebuild test -project Corvo.xcodeproj -scheme Corvo \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS'

# Quits first: the app is a background agent with a global shortcut, so a second
# copy is not a second window — it is a second poller racing the first for the
# same clipboard and the same database.
run: build
	@pkill -x Corvo || true
	@sleep 1
	open $(DERIVED)/Build/Products/Debug/Corvo.app

release: gen
	rm -rf build
	xcodebuild -project Corvo.xcodeproj -scheme Corvo -configuration Release \
		-derivedDataPath build/dd build
	mkdir -p build
	ditto -c -k --keepParent build/dd/Build/Products/Release/Corvo.app build/Corvo.zip
	@echo "built: build/Corvo.zip"

clean:
	rm -rf Corvo.xcodeproj build DerivedData
