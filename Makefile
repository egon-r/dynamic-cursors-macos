.PHONY: app run smoke clean

app:
	swift build -c release
	mkdir -p "build/Dynamic Cursors.app/Contents/MacOS" "build/Dynamic Cursors.app/Contents/Resources"
	cp .build/release/DynamicCursors "build/Dynamic Cursors.app/Contents/MacOS/DynamicCursors"
	cp Info.plist "build/Dynamic Cursors.app/Contents/Info.plist"
	cp LICENSE "build/Dynamic Cursors.app/Contents/Resources/LICENSE"
	codesign --force --sign - "build/Dynamic Cursors.app"

run: app
	open "build/Dynamic Cursors.app"

smoke: app
	"build/Dynamic Cursors.app/Contents/MacOS/DynamicCursors" --smoke

clean:
	rm -rf .build build
