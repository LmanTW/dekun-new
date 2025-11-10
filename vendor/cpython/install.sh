#!/bin/bash

set -e
cd $(dirname "${BASH_SOURCE[0]}")

CPYTHON_VERSION_MAJOR=$(sed -n 's/.*\.major *= *\([0-9]*\),*/\1/p' ../../build.zig.zon)
CPYTHON_VERSION_MINOR=$(sed -n 's/.*\.minor *= *\([0-9]*\),*/\1/p' ../../build.zig.zon)
CPYTHON_VERSION_PATCH=$(sed -n 's/.*\.patch *= *\([0-9]*\),*/\1/p' ../../build.zig.zon)
CPYTHON_VERSION_RELEASE=$(sed -n 's/.*\.release *= "*\([0-9]*\)"*/\1/p' ../../build.zig.zon)

if [[ ! -d ./include/x86_64-linux ]]; then
  mkdir -p ./include/x86_64-linux && curl -fL "https://github.com/astral-sh/python-build-standalone/releases/download/${CPYTHON_VERSION_RELEASE}/cpython-${CPYTHON_VERSION_MAJOR}.${CPYTHON_VERSION_MINOR}.${CPYTHON_VERSION_PATCH}+${CPYTHON_VERSION_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" | tar -vxz --strip-components 3 -C ./include/x86_64-linux "python/include/python${CPYTHON_VERSION_MAJOR}.${CPYTHON_VERSION_MINOR}"
fi

if [[ ! -d ./include/aarch64-linux ]]; then
  mkdir -p ./include/aarch64-linux && curl -fL "https://github.com/astral-sh/python-build-standalone/releases/download/${CPYTHON_VERSION_RELEASE}/cpython-${CPYTHON_VERSION_MAJOR}.${CPYTHON_VERSION_MINOR}.${CPYTHON_VERSION_PATCH}+${CPYTHON_VERSION_RELEASE}-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz" | tar -vxz --strip-components 3 -C ./include/aarch64-linux "python/include/python${CPYTHON_VERSION_MAJOR}.${CPYTHON_VERSION_MINOR}"
fi

if [[ ! -d ./include/x86_64-macos ]]; then
  mkdir -p ./include/x86_64-macos && curl -fL "https://github.com/astral-sh/python-build-standalone/releases/download/${CPYTHON_VERSION_RELEASE}/cpython-${CPYTHON_VERSION_MAJOR}.${CPYTHON_VERSION_MINOR}.${CPYTHON_VERSION_PATCH}+${CPYTHON_VERSION_RELEASE}-x86_64-apple-darwin-install_only_stripped.tar.gz" | tar -vxz --strip-components 3 -C ./include/x86_64-macos "python/include/python${CPYTHON_VERSION_MAJOR}.${CPYTHON_VERSION_MINOR}"
fi

if [[ ! -d ./include/aarch64-macos ]]; then
  mkdir -p ./include/aarch64-macos && curl -fL "https://github.com/astral-sh/python-build-standalone/releases/download/${CPYTHON_VERSION_RELEASE}/cpython-${CPYTHON_VERSION_MAJOR}.${CPYTHON_VERSION_MINOR}.${CPYTHON_VERSION_PATCH}+${CPYTHON_VERSION_RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz" | tar -vxz --strip-components 3 -C ./include/aarch64-macos "python/include/python${CPYTHON_VERSION_MAJOR}.${CPYTHON_VERSION_MINOR}"
fi

if [[ ! -d ./include/x86_64-windows ]]; then
  mkdir -p ./include/x86_64-windows && curl -fL "https://github.com/astral-sh/python-build-standalone/releases/download/${CPYTHON_VERSION_RELEASE}/cpython-${CPYTHON_VERSION_MAJOR}.${CPYTHON_VERSION_MINOR}.${CPYTHON_VERSION_PATCH}+${CPYTHON_VERSION_RELEASE}-x86_64-pc-windows-msvc-install_only_stripped.tar.gz" | tar -vxz --strip-components 2 -C ./include/x86_64-windows "python/include"
fi

if [[ ! -d ./include/aarch64-windows ]]; then
  mkdir -p ./include/aarch64-windows && curl -fL "https://github.com/astral-sh/python-build-standalone/releases/download/${CPYTHON_VERSION_RELEASE}/cpython-${CPYTHON_VERSION_MAJOR}.${CPYTHON_VERSION_MINOR}.${CPYTHON_VERSION_PATCH}+${CPYTHON_VERSION_RELEASE}-aarch64-pc-windows-msvc-install_only_stripped.tar.gz" | tar -vxz --strip-components 2 -C ./include/aarch64-windows "python/include"
fi
