#!/bin/sh
set -eu
apps_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# XcodeGen is supplied by the developer (brew install xcodegen); nothing installs globally.
xcodegen_bin=${XCODEGEN_BIN:-xcodegen}
exec "$xcodegen_bin" generate --spec "$apps_dir/project.yml" --project "$apps_dir"
