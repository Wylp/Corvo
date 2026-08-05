.PHONY: gen build test run release clean

gen:
	xcodegen generate

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
	mkdir -p build
	ditto -c -k --keepParent build/dd/Build/Products/Release/Corvo.app build/Corvo.zip
	@echo "built: build/Corvo.zip"

clean:
	rm -rf Corvo.xcodeproj build DerivedData
