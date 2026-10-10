#!/usr/bin/env bash
#
# libcurl 跨平台构建脚本 (仅 Linux)
#
# 用法:
#   ./scripts/build-linux.sh <platform> [options]
#
# 平台:
#   linux-x86_64         Linux x86_64 (原生或交叉编译)
#   linux-arm64          Linux aarch64 (原生或交叉编译)
#
# 选项:
#   --clean              清理该平台的 build 目录后重新编译
#   --curl-cli           额外编译 curl 命令行工具
#   --jobs <N>           并行编译线程数 (默认自动检测)
#
set -eo pipefail

# ============================================================
# 项目路径
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPS_SRC="$PROJECT_ROOT/deps"
CURL_SRC="$DEPS_SRC/curl"
BRIDGE_SRC="$PROJECT_ROOT/bridge/curl_unity_bridge.c"
OUTPUT_DIR="$PROJECT_ROOT/output"

# ============================================================
# 默认参数
# ============================================================
CLEAN=0
BUILD_CURL_CLI=0
JOBS="$(nproc 2>/dev/null || echo 4)"

# ============================================================
# 参数解析
# ============================================================
PLATFORM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)        CLEAN=1; shift ;;
    --curl-cli)     BUILD_CURL_CLI=1; shift ;;
    --jobs)         JOBS="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,/^$/p' "$0" | sed 's/^#//; s/^ //'
      exit 0
      ;;
    -*)
      echo "错误: 未知选项 $1" >&2; exit 1 ;;
    *)
      if [[ -z "$PLATFORM" ]]; then
        PLATFORM="$1"
      else
        echo "错误: 多余参数 $1" >&2; exit 1
      fi
      shift ;;
  esac
done

if [[ -z "$PLATFORM" ]]; then
  echo "错误: 请指定目标平台。运行 $0 --help 查看用法。" >&2
  exit 1
fi

# ============================================================
# 平台配置
# ============================================================
CMAKE_EXTRA_ARGS=()
OPENSSL_TARGET=""
OPENSSL_EXTRA_ARGS=()
CURL_SHARED=OFF
CURL_STATIC=ON

configure_platform() {
  local host_arch
  host_arch="$(uname -m)"

  case "$PLATFORM" in
    linux-x86_64)
      OPENSSL_TARGET="linux-x86_64"
      OPENSSL_EXTRA_ARGS=()
      CMAKE_EXTRA_ARGS=(
        -DCMAKE_SYSTEM_NAME=Linux
        -DCMAKE_SYSTEM_PROCESSOR=x86_64
      )
      ;;
    linux-arm64)
      OPENSSL_TARGET="linux-aarch64"
      OPENSSL_EXTRA_ARGS=()
      CMAKE_EXTRA_ARGS=(
        -DCMAKE_SYSTEM_NAME=Linux
        -DCMAKE_SYSTEM_PROCESSOR=aarch64
      )
      # 非 ARM 宿主机，配置交叉编译前缀
      if [[ "$host_arch" != "aarch64" && "$host_arch" != "arm64" ]]; then
        export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
        # 仅传给 CMake，不 export 带前缀的 CC，防止 OpenSSL 内部重复拼接前缀
        CMAKE_EXTRA_ARGS+=(
          -DCMAKE_C_COMPILER="${CROSS_COMPILE}gcc"
          -DCMAKE_CXX_COMPILER="${CROSS_COMPILE}g++"
        )
      fi
      ;;
    *)
      echo "错误: 不支持的平台 '$PLATFORM'" >&2
      exit 1
      ;;
  esac
}

# ============================================================
# 工具函数
# ============================================================
log() {
  echo ""
  echo "========================================"
  echo "  $1"
  echo "========================================"
  echo ""
}

step_time() {
  date +%s
}

elapsed() {
  local start=$1
  local end
  end=$(date +%s)
  echo "$(( end - start ))s"
}

ensure_submodules() {
  local repo_dir="$1"
  shift
  if [[ ! -f "$repo_dir/.gitmodules" ]]; then return; fi

  pushd "$repo_dir" > /dev/null
  if [[ $# -gt 0 ]]; then
    for path in "$@"; do
      if [[ ! -e "$path/.git" ]]; then
        echo "  初始化子模块: $(basename "$repo_dir")/$path"
        git submodule update --init --depth 1 -- "$path"
      fi
    done
  else
    if git submodule status | grep -q '^-'; then
      echo "  初始化子模块: $(basename "$repo_dir")"
      git submodule update --init --depth 1
    fi
  fi
  popd > /dev/null
}

# ============================================================
# 构建函数
# ============================================================

build_zlib() {
  if [[ -f "$PREFIX/lib/libz.a" ]]; then
    echo "  [跳过] zlib 已编译"
    return
  fi

  log "[$PLATFORM] 编译 zlib"
  local start=$(step_time)

  local build_dir="$PROJECT_ROOT/build/$PLATFORM/zlib"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  cp -r "$DEPS_SRC/zlib" "$build_dir/src"
  cd "$build_dir/src"

  # 配置交叉编译器并生成静态库
  if [[ -n "${CROSS_COMPILE:-}" ]]; then
    CHOST="${CROSS_COMPILE%-}" CC="${CROSS_COMPILE}gcc" ./configure --prefix="$PREFIX" --static
  else
    ./configure --prefix="$PREFIX" --static
  fi

  make -j"$JOBS"
  make install
  echo "  zlib 完成 ($(elapsed "$start"))"
}

build_openssl() {
  if [[ -f "$PREFIX/lib/libssl.a" && -f "$PREFIX/lib/libcrypto.a" ]]; then
    echo "  [跳过] OpenSSL 已编译"
    return
  fi

  log "[$PLATFORM] 编译 OpenSSL"
  local start
  start=$(step_time)

  local build_dir="$PROJECT_ROOT/build/$PLATFORM/openssl"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  cd "$build_dir"

  local openssl_args=(
    "$OPENSSL_TARGET"
    --prefix="$PREFIX"
    --libdir=lib
    no-shared
    no-tests
    no-apps
    -fPIC
  )

  "$DEPS_SRC/openssl/Configure" "${openssl_args[@]}"

  make -j"$JOBS"
  make install_sw

  echo "  OpenSSL 完成 ($(elapsed "$start"))"
}

build_nghttp2() {
  if [[ -f "$PREFIX/lib/libnghttp2.a" ]]; then
    echo "  [跳过] nghttp2 已编译"
    return
  fi

  log "[$PLATFORM] 编译 nghttp2"
  local start
  start=$(step_time)

  rm -f "$PREFIX"/lib/libnghttp2*

  local build_dir="$PROJECT_ROOT/build/$PLATFORM/nghttp2"
  rm -rf "$build_dir"

  cmake -B "$build_dir" -S "$DEPS_SRC/nghttp2" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DENABLE_LIB_ONLY=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    "${CMAKE_EXTRA_ARGS[@]}"

  cmake --build "$build_dir" -j "$JOBS"
  cmake --install "$build_dir"

  echo "  nghttp2 完成 ($(elapsed "$start"))"
}

build_nghttp3() {
  if [[ -f "$PREFIX/lib/libnghttp3.a" ]]; then
    echo "  [跳过] nghttp3 已编译"
    return
  fi

  log "[$PLATFORM] 编译 nghttp3"
  local start
  start=$(step_time)

  ensure_submodules "$DEPS_SRC/nghttp3" "lib/sfparse"

  rm -f "$PREFIX"/lib/libnghttp3*

  local build_dir="$PROJECT_ROOT/build/$PLATFORM/nghttp3"
  rm -rf "$build_dir"

  cmake -B "$build_dir" -S "$DEPS_SRC/nghttp3" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DENABLE_LIB_ONLY=ON \
    -DBUILD_TESTING=OFF \
    -DENABLE_SHARED_LIB=OFF \
    -DENABLE_STATIC_LIB=ON \
    "${CMAKE_EXTRA_ARGS[@]}"

  cmake --build "$build_dir" -j "$JOBS"
  cmake --install "$build_dir"

  echo "  nghttp3 完成 ($(elapsed "$start"))"
}

build_ngtcp2() {
  if [[ -f "$PREFIX/lib/libngtcp2.a" ]]; then
    echo "  [跳过] ngtcp2 已编译"
    return
  fi

  log "[$PLATFORM] 编译 ngtcp2"
  local start
  start=$(step_time)

  rm -f "$PREFIX"/lib/libngtcp2*

  local build_dir="$PROJECT_ROOT/build/$PLATFORM/ngtcp2"
  rm -rf "$build_dir"

  cmake -B "$build_dir" -S "$DEPS_SRC/ngtcp2" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DOPENSSL_ROOT_DIR="$PREFIX" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DENABLE_OPENSSL=ON \
    -DENABLE_LIB_ONLY=ON \
    -DBUILD_TESTING=OFF \
    -DENABLE_SHARED_LIB=OFF \
    -DENABLE_STATIC_LIB=ON \
    "${CMAKE_EXTRA_ARGS[@]}"

  cmake --build "$build_dir" -j "$JOBS"
  cmake --install "$build_dir"

  echo "  ngtcp2 完成 ($(elapsed "$start"))"
}

_curl_common_args() {
  echo \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DOPENSSL_ROOT_DIR="$PREFIX" \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_LIBCURL_DOCS=OFF \
    -DBUILD_MISC_DOCS=OFF \
    -DENABLE_CURL_MANUAL=OFF \
    -DCURL_ENABLE_SSL=ON \
    -DCURL_USE_OPENSSL=ON \
    -DCURL_USE_PKGCONFIG=OFF \
    -DENABLE_ARES=OFF \
    -DENABLE_THREADED_RESOLVER=ON \
    -DENABLE_IPV6=ON \
    -DUSE_NGHTTP2=ON \
    -DUSE_NGTCP2=ON \
    -DHTTP_ONLY=ON \
    -DCURL_USE_LIBPSL=OFF \
    -DCURL_USE_LIBSSH2=OFF \
    -DCURL_USE_LIBSSH=OFF \
    -DCURL_ZLIB=ON \
    -DCURL_BROTLI=OFF \
    -DCURL_ZSTD=OFF \
    -DUSE_LIBIDN2=OFF \
    -DCURL_DISABLE_LDAP=ON \
    -DCURL_DISABLE_LDAPS=ON \
    -DCURL_DISABLE_AWS=ON \
    -DCURL_DISABLE_KERBEROS_AUTH=ON \
    -DCURL_DISABLE_NEGOTIATE_AUTH=ON \
    -DCURL_DISABLE_VERBOSE_STRINGS=OFF \
    -DCURL_LTO=ON \
    -DCURL_CA_PATH=/etc/ssl/certs
}

build_libcurl() {
  if [[ -f "$PREFIX/lib/libcurl.a" ]]; then
    echo "  [跳过] libcurl 已编译"
    return
  fi

  log "[$PLATFORM] 编译 libcurl"
  local start
  start=$(step_time)

  rm -rf "$PREFIX/lib/cmake/nghttp2" "$PREFIX/lib/cmake/nghttp3" "$PREFIX/lib/cmake/ngtcp2"

  local build_dir="$PROJECT_ROOT/build/$PLATFORM/curl"
  rm -rf "$build_dir"

  cmake -B "$build_dir" -S "$CURL_SRC" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_CURL_EXE=OFF \
    -DBUILD_SHARED_LIBS="$CURL_SHARED" \
    -DBUILD_STATIC_LIBS="$CURL_STATIC" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    $(_curl_common_args) \
    "${CMAKE_EXTRA_ARGS[@]}"

  cmake --build "$build_dir" -j "$JOBS"
  cmake --install "$build_dir"

  echo "  libcurl 完成 ($(elapsed "$start"))"
}

build_curl_cli() {
  log "[$PLATFORM] 编译 curl CLI (静态链接)"
  local start
  start=$(step_time)

  local build_dir="$PROJECT_ROOT/build/$PLATFORM/curl-cli"
  local cli_prefix="$PROJECT_ROOT/build/$PLATFORM/curl-cli-install"
  rm -rf "$build_dir"
  mkdir -p "$cli_prefix"

  cmake -B "$build_dir" -S "$CURL_SRC" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$cli_prefix" \
    -DBUILD_CURL_EXE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_STATIC_CURL=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    $(_curl_common_args) \
    "${CMAKE_EXTRA_ARGS[@]}"

  cmake --build "$build_dir" -j "$JOBS"
  cmake --install "$build_dir"

  # 收集 CLI 产物
  local arch
  [[ "$PLATFORM" == "linux-x86_64" ]] && arch="x86_64" || arch="arm64"
  local out="$OUTPUT_DIR/Linux/$arch"
  
  mkdir -p "$out"
  cp -f "$cli_prefix/bin/curl" "$out/curl"
  echo "  -> $out/curl"
  echo "  curl CLI 完成 ($(elapsed "$start"))"
}

# ============================================================
# 产物收集
# ============================================================

_all_static_libs() {
  echo \
    "$PREFIX/lib/libcurl.a" \
    "$PREFIX/lib/libssl.a" \
    "$PREFIX/lib/libcrypto.a" \
    "$PREFIX/lib/libnghttp2.a" \
    "$PREFIX/lib/libngtcp2.a" \
    "$PREFIX/lib/libngtcp2_crypto_ossl.a" \
    "$PREFIX/lib/libnghttp3.a"
}

collect_output() {
  log "[$PLATFORM] 编译 bridge + 收集产物"

  case "$PLATFORM" in
    linux-x86_64)
      _collect_linux "$OUTPUT_DIR/Linux/x86_64"
      ;;
    linux-arm64)
      _collect_linux "$OUTPUT_DIR/Linux/arm64"
      ;;
  esac
}

_collect_linux() {
  local out="$1"
  mkdir -p "$out"

  local compiler
  if [[ -n "${CROSS_COMPILE:-}" ]]; then
    compiler="${CROSS_COMPILE}gcc"
  else
    compiler="${CC:-cc}"
  fi

  # 1. 编译 bridge.o
  "$compiler" -fPIC -O2 -c \
    -I"$PREFIX/include" \
    "$BRIDGE_SRC" \
    -o "$out/bridge.o"

  # 2. 链接 .so
  # 如果 PREFIX 目录下有 libz.a，直接链接该静态库；否则使用 -L"$PREFIX/lib" -lz
  local zlib_link="-lz"
  if [[ -f "$PREFIX/lib/libz.a" ]]; then
    zlib_link="$PREFIX/lib/libz.a"
  fi

  "$compiler" -shared -fPIC -o "$out/libcurl.so" \
    "$out/bridge.o" \
    -L"$PREFIX/lib" \
    -Wl,--whole-archive "$PREFIX/lib/libcurl.a" -Wl,--no-whole-archive \
    $(_all_static_libs | sed "s|$PREFIX/lib/libcurl.a||") \
    "$zlib_link" -lpthread -ldl

  rm -f "$out/bridge.o"
  echo "  -> $out/libcurl.so"
}

# ============================================================
# 主流程
# ============================================================
main() {
  echo "========================================"
  echo "  libcurl 构建脚本 (Linux)"
  echo "  平台: $PLATFORM"
  echo "  项目: $PROJECT_ROOT"
  echo "========================================"

  configure_platform

  PREFIX="$PROJECT_ROOT/build/$PLATFORM/install"

  if [[ "$CLEAN" == "1" ]]; then
    echo "清理 build/$PLATFORM ..."
    rm -rf "$PROJECT_ROOT/build/$PLATFORM"
  fi

  mkdir -p "$PREFIX"

  local total_start
  total_start=$(step_time)

  build_zlib
  build_openssl
  build_nghttp2
  build_nghttp3
  build_ngtcp2

  if [[ "$BUILD_CURL_CLI" == "1" ]]; then
    build_curl_cli
  else
    build_libcurl
    collect_output
  fi

  log "全部完成! 总耗时: $(elapsed "$total_start")"
  echo "安装目录: $PREFIX"
  echo "产物目录: $OUTPUT_DIR"
}

main
