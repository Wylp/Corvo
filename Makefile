.PHONY: gen build test run clean

gen:
	xcodegen generate

build: gen
	xcodebuild -project Corvo.xcodeproj -scheme Corvo -configuration Debug build

test: gen
	xcodebuild test -project Corvo.xcodeproj -scheme Corvo -destination 'platform=macOS'

run: build
	open ~/Library/Developer/Xcode/DerivedData/Corvo-*/Build/Products/Debug/Corvo.app

clean:
	rm -rf Corvo.xcodeproj build DerivedData
