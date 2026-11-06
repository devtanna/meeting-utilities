export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

DEBUG_APP   := build/dd/Build/Products/Debug/MeetingUtility.app
RELEASE_APP := build/dd/Build/Products/Release/MeetingUtility.app

.PHONY: help dev dev-fake dev-attached build release publish publish-dry test bootstrap open stop clean

help:
	@echo "make dev        Build (Debug), launch as a real app (permission prompts work), stream logs; Ctrl-C quits"
	@echo "make dev-fake   Same, with the synthetic calendar and a separate sandbox database"
	@echo "make dev-attached  Run the binary attached to the terminal (debug output; no permission prompts)"
	@echo "make build      Debug build only"
	@echo "make release    Release build + DMG/zip in dist/"
	@echo "make publish    Bump version (BUMP=patch|minor|major|X.Y.Z, default patch), test, build, tag, push, GitHub release"
	@echo "make publish-dry  Same bump + test + build, but nothing is committed or pushed"
	@echo "make test       Unit tests + model-manifest check"
	@echo "make open       Launch the last Debug build detached (like double-clicking)"
	@echo "make stop       Quit any running copy"
	@echo "make bootstrap  Check toolchain, generate the Xcode project, resolve packages"
	@echo "make clean      Remove build/ and dist/"

LOGS := log stream --style compact --level info --predicate 'subsystem BEGINSWITH "com.devtanna.meetingutils"'

## Build Debug, stop any running copy (single-instance app), launch it through LaunchServices so macOS attributes
## privacy prompts (Calendar, Microphone, Notifications) to the app itself, and stream its logs here.
## Ctrl-C stops log streaming and quits the app.
dev: build stop
	@$(LOGS) & LOG=$$!; trap 'kill $$LOG 2>/dev/null; pkill -x MeetingUtility' INT TERM EXIT; \
	  open -W $(DEBUG_APP)

dev-fake: build stop
	@$(LOGS) & LOG=$$!; trap 'kill $$LOG 2>/dev/null; pkill -x MeetingUtility' INT TERM EXIT; \
	  open -W $(DEBUG_APP) --args -UseFakeCalendar YES

## Runs the binary attached to this terminal (stdout/stderr here). NOTE: macOS then treats the terminal as the
## responsible app, so permission prompts go to the terminal instead of Meeting Utility.
dev-attached: build stop
	$(DEBUG_APP)/Contents/MacOS/MeetingUtility

build:
	scripts/build.sh Debug

release:
	scripts/release.sh

## Optional NOTES=path/to/highlights.md is shown above the generated changelog.
BUMP ?= patch
publish:
	NOTES="$(NOTES)" scripts/publish.sh $(BUMP)

publish-dry:
	DRY_RUN=1 NOTES="$(NOTES)" scripts/publish.sh $(BUMP)

test:
	scripts/test.sh

open: stop
	open $(DEBUG_APP)

stop:
	-@pkill -x MeetingUtility 2>/dev/null; sleep 0.5

bootstrap:
	scripts/bootstrap.sh

clean:
	rm -rf build dist
