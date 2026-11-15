# CI runs `make lint`, `make test`, and `make build` on macOS.

.PHONY: lint test build app check

lint:
	swift build -Xswiftc -warnings-as-errors
	zsh -n scripts/build-app.sh
	python3 -m py_compile scripts/gen_s300_tables.py

test:
	swift test

build:
	swift build -c release

app:
	scripts/build-app.sh

check: lint test build
