.PHONY: build lint test package icon

build:
	swift build

lint:
	shellcheck scripts/*.sh
	plutil -lint Resources/PrivacyInfo.xcprivacy

test: lint
	swift build -c debug

package:
	./scripts/package-internal.sh

icon:
	./scripts/generate-icon.sh
