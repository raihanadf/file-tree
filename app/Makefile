APP = FileTree.app

app:
	swift build -c release
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/FileTree $(APP)/Contents/MacOS/FileTree
	cp Info.plist $(APP)/Contents/Info.plist
	mkdir -p $(APP)/Contents/Resources
	xcrun actool AppIcon.icon --compile $(APP)/Contents/Resources --platform macosx --minimum-deployment-target 26.0 \
		--app-icon AppIcon --output-partial-info-plist .build/icon.plist >/dev/null
	codesign --force -s - $(APP)

install: app
	rm -rf $(HOME)/Applications/$(APP)
	cp -R $(APP) $(HOME)/Applications/$(APP)

clean:
	rm -rf .build $(APP)

.PHONY: app install clean
