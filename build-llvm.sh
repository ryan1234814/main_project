#!/bin/bash
set -e
cd ~/llvm
echo "[1/4] Downloading LLVM 18.1.8 source tarball..."
curl -sL -o llvm-project-18.1.8.src.tar.xz https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/llvm-project-18.1.8.src.tar.xz
echo "[2/4] Extracting..."
rm -rf llvm-project-src
mkdir llvm-project-src
tar -xJf llvm-project-18.1.8.src.tar.xz -C llvm-project-src --strip-components=1
echo "[3/4] Configuring (Release, MLIR, host+RISCV targets)..."
cmake -G Ninja ~/llvm/llvm-project-src/llvm \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS=mlir \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_TARGETS_TO_BUILD="host;RISCV" \
  -DLLVM_OPTIMIZED_TABLEGEN=ON \
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_DOCS=OFF -DLLVM_ENABLE_BINDINGS=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DBISON_EXECUTABLE=/opt/homebrew/opt/bison/bin/bison \
  -DFLEX_EXECUTABLE=/opt/homebrew/opt/flex/bin/flex \
  -B ~/llvm/build-rel
echo "[4/4] Building (this takes a while)..."
cmake --build ~/llvm/build-rel -- -j10
echo "LLVM_BUILD_COMPLETE_OK"

