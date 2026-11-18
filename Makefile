APP_NAME := Sleepwalker
APP := build/$(APP_NAME).app
DMG := build/$(APP_NAME).dmg
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
INSTALL_DIR := /Applications
SUDOERS_RULE := /private/etc/sudoers.d/sleepwalker
# Espera (hasta 5 s) a que Sleepwalker termine de cerrarse: al salir restaura la suspensión con la tapa cerrada.
WAIT_FOR_EXIT = for i in $$(seq 25); do pgrep -x $(APP_NAME) >/dev/null || break; sleep 0.2; done

.PHONY: all app run install uninstall dmg release icon clean

all: app

# Binario universal (Apple Silicon e Intel). Sin Xcode, SwiftPM compila una arquitectura a la vez.
app:
	swift build -c release --arch arm64
	swift build -c release --arch x86_64
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	lipo -create -output "$(APP)/Contents/MacOS/$(APP_NAME)" \
		".build/arm64-apple-macosx/release/$(APP_NAME)" ".build/x86_64-apple-macosx/release/$(APP_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --sign - "$(APP)"
	@echo "Listo: $(APP)"

run: app
	open "$(APP)"

install: app
	-pkill -x $(APP_NAME)
	@$(WAIT_FOR_EXIT)
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/$(APP_NAME).app"

uninstall:
	-pkill -x $(APP_NAME)
	@$(WAIT_FOR_EXIT)
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@if [ -e $(SUDOERS_RULE) ]; then echo "Quitando el permiso de la tapa cerrada (pide tu contraseña)"; sudo rm -f $(SUDOERS_RULE); fi

# Imagen de disco para distribuir: la app y un acceso a Aplicaciones, con el ícono de la app en el volumen.
# El ícono del volumen solo se puede marcar con la imagen montada, por eso se arma en lectura/escritura y luego se comprime.
dmg: app
	rm -rf build/dmg build/dmg-rw.dmg "$(DMG)"
	mkdir -p build/dmg
	ditto "$(APP)" "build/dmg/$(APP_NAME).app"
	ln -s /Applications build/dmg/Applications
	cp Resources/AppIcon.icns build/dmg/.VolumeIcon.icns
	mkdir build/dmg/.fseventsd
	touch build/dmg/.fseventsd/no_log  # que macOS no guarde en la imagen el registro de cambios al montarla
	hdiutil create -quiet -srcfolder build/dmg -volname "$(APP_NAME)" -fs HFS+ -format UDRW build/dmg-rw.dmg
	hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$(CURDIR)/build/dmg-mnt" build/dmg-rw.dmg
	SetFile -a C build/dmg-mnt
	hdiutil detach -quiet build/dmg-mnt
	hdiutil convert -quiet build/dmg-rw.dmg -format UDZO -imagekey zlib-level=9 -o "$(DMG)"
	rm -rf build/dmg build/dmg-rw.dmg
	@echo "Listo: $(DMG)"

# Publica en GitHub la versión de Resources/Info.plist con el .dmg (requiere gh). Sube antes la versión en Info.plist.
release: dmg
	gh release create "v$(VERSION)" "$(DMG)" --title "$(APP_NAME) $(VERSION)" --generate-notes

# Regenera el ícono de la app (y el del README) a partir de scripts/make-icon.swift.
icon:
	swift scripts/make-icon.swift Resources/AppIcon.iconset
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	mkdir -p docs
	cp Resources/AppIcon.iconset/icon_128x128@2x.png docs/icon.png
	rm -rf Resources/AppIcon.iconset

clean:
	rm -rf .build build
