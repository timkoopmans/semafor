# Semafor build tasks. Run `just` to list recipes.

set quiet

default:
    just --list

# Compile the Swift package (debug)
build *args:
    swift build {{args}}

# Run the test suite
test *args:
    swift test {{args}}

# Build a debug test app bundle in dist/ (kills/cleans older test bundles)
dev:
    scripts/dev_build.sh

# Build the test app bundle and launch it
run:
    OPEN_APP=1 scripts/build_test_app.sh

# Run tests, then build the test app bundle
dev-test:
    scripts/dev_test.sh

# Opt-in live endpoint smoke tool (prints redacted live payloads; Task 6)
live-smoke provider="claude" *args:
    swift run SemaforSmoke {{provider}} {{args}}

# Opt-in passive extractor shape-check against real session logs (claude/codex) or the OpenCode db (hal) (Task 12)
live-scan provider="claude" days="7":
    swift run SemaforSmoke scan {{provider}} --days {{days}}

# Build a release .app in dist/ (ad-hoc signed unless CODESIGN_IDENTITY is set)
package version="0.1.0":
    APP_NAME=Semafor VERSION={{version}} scripts/package_app.sh

# Build a release .app only, no DMG
app version="0.1.0":
    SKIP_DMG=1 APP_NAME=Semafor VERSION={{version}} scripts/package_app.sh

# Build a release .app and install it to ~/Applications, replacing any running copy
deploy version="0.1.0": (app version)
    pkill -f 'Semafor.*\.app/Contents/MacOS/' || true
    rm -rf ~/Applications/Semafor.app
    cp -R dist/Semafor.app ~/Applications/Semafor.app
    open ~/Applications/Semafor.app
    echo "Deployed Semafor {{version}} to ~/Applications"

# Remove build artifacts and app bundles
clean:
    rm -rf .build dist
