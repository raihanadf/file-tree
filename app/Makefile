APP = FileTree.app

app:
	swift build -c release
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/FileTree $(APP)/Contents/MacOS/FileTree
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force -s - $(APP)

install: app
	rm -rf $(HOME)/Applications/$(APP)
	cp -R $(APP) $(HOME)/Applications/$(APP)

clean:
	rm -rf .build $(APP)

.PHONY: app install clean
