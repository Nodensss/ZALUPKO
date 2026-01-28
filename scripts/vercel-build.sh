#!/usr/bin/env bash
set -euo pipefail

if [ ! -d flutter ]; then
  git clone https://github.com/flutter/flutter.git -b stable --depth 1 flutter
fi

export PATH="$PWD/flutter/bin:$PATH"
flutter --version
flutter config --enable-web
flutter pub get
flutter build web --release

rm -rf public
mkdir -p public
cp -r build/web/* public/
