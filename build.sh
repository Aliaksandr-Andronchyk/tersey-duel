#!/bin/zsh
# Сборка TerseyDuel. Подпись ad-hoc; свой сертификат: IDENTITY="..." ./build.sh
set -e
cd "$(dirname "$0")"
clang -c cube.s -o cube.o
swiftc -O terseyduel.swift cube.o -o TerseyDuel

APP=${APP:-~/Applications/TerseyDuel.app}
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp TerseyDuel "$APP/Contents/MacOS/TerseyDuel"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "готово: $APP"
