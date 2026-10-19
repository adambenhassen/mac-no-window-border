APP = build/NoBorder.app

all: app

build/AppIcon.icns: app/make-icon.swift
	mkdir -p build
	swift app/make-icon.swift $@

app: build/AppIcon.icns
	cd app && swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp app/Info.plist $(APP)/Contents/Info.plist
	cp app/.build/release/NoBorder $(APP)/Contents/MacOS/NoBorder
	cp build/AppIcon.icns $(APP)/Contents/Resources/
	codesign --force --sign - --entitlements app/Entitlements.plist $(APP)

# Development binary for driving the native engine by hand (tests/probe.sh drives it).
probe:
	cd app && swift build
	mkdir -p build
	cp app/.build/debug/noborder-probe build/noborder-probe
	codesign --force --sign - --entitlements app/Entitlements.plist build/noborder-probe

release: app
	rm -f build/NoBorder.zip
	ditto -c -k --keepParent $(APP) build/NoBorder.zip

install: app
	rm -rf /Applications/NoBorder.app
	cp -R $(APP) /Applications/

test:
	cd app && swift test
	$(MAKE) testtools probe
	tests/probe.sh
	tests/engine.sh

testtools: tests/hostapp tests/winpixels tests/pxband tests/wbounds tests/plainrunloop

tests/hostapp: tests/hostapp.swift
	swiftc -O -o $@ $<

tests/winpixels: tests/winpixels.c
	clang -O2 -Wall -o $@ $< -framework CoreGraphics -framework ImageIO -framework CoreFoundation

# Strip comparison across a window's edge: the outline check (tests/e2e.sh).
tests/pxband: tests/pxband.c
	clang -O2 -Wall -o $@ $< -framework CoreGraphics -framework ImageIO -framework CoreFoundation

# A window's rectangle, to place that strip.
tests/wbounds: tests/wbounds.m
	clang -O2 -Wall -fobjc-arc -o $@ $< -framework AppKit -framework CoreGraphics

# A main run loop with no AppKit: the target the native engine must refuse.
tests/plainrunloop: tests/plainrunloop.swift
	swiftc -O -o $@ $<

# The pause benchmark: the app's own measure of how long each engine stops its main loop.
bench: testtools probe
	tests/pausebench.sh

clean:
	rm -rf build app/.build tests/hostapp tests/winpixels tests/pxband tests/wbounds tests/plainrunloop

.PHONY: all app probe release install test testtools bench clean
