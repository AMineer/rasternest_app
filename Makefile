.PHONY: help build test app run cli dmg brand linux-check clean

help:
	@echo "make build        Debug build of everything"
	@echo "make test         Run unit tests"
	@echo "make app          Build + sign build/RasterNest.app"
	@echo "make run          Build the app and launch it"
	@echo "make cli          Build a release rnest tarball for this OS"
	@echo "make dmg          Universal app + DMG in build/"
	@echo "make brand        Regenerate the icon, site images and README banners"
	@echo "make linux-check  Build + test the Linux CLI in Docker"

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

run: app
	-pkill -x RasterNest
	open build/RasterNest.app

cli:
	./scripts/package-cli.sh

dmg:
	UNIVERSAL=1 ./scripts/build-app.sh
	./scripts/make-dmg.sh

brand:
	swift scripts/generate-brand.swift

linux-check:
	docker run --rm -v "$(CURDIR)":/src -w /src swift:6.0 \
		bash -c "swift build --product rnest --scratch-path /tmp/.build && swift test --scratch-path /tmp/.build && /tmp/.build/debug/rnest --help"

clean:
	rm -rf .build build
