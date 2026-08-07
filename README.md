# libcurl-unity

A libcurl build tailored for unity

## Supported Platforms

| Platform | Architecture                   | Output                       | Minimum Version              |
| -------- | ------------------------------ | ---------------------------- | ---------------------------- |
| macOS    | ARM64                          | `libcurl.dylib`              | macOS 11.0+ (Big Sur)        |
| macOS    | x86_64                         | `libcurl.dylib`              | macOS 10.14+ (Mojave)        |
| iOS      | ARM64                          | `libcurl.a` (static library) | iOS 12.0                     |
| Android  | arm64-v8a, armeabi-v7a, x86_64 | `libcurl.so`                 | Android API 22 (Android 5.1) |
| Windows  | x64, x86                       | `libcurl.dll`                | Windows 7 SP1+               |

## Dependencies

All dependencies are built as static libraries and linked into a single distributable library

| Library                                 | Version | Purpose                               |
| --------------------------------------- | ------- | ------------------------------------- |
| [curl](https://curl.se/)                | 8.21.0  | Core HTTP client functionality        |
| [OpenSSL](https://www.openssl.org/)     | 3.6.2   | TLS / HTTPS support                   |
| [nghttp2](https://nghttp2.org/)         | 1.68.1  | HTTP/2 support                        |
| [nghttp3](https://nghttp2.org/nghttp3/) | 1.15.0  | HTTP/3 support                        |
| [ngtcp2](https://nghttp2.org/ngtcp2/)   | 1.21.0  | QUIC transport support                |
| [zlib](https://zlib.net/)               | 1.3.2   | Compression support (Windows/Android) |

## Project Structure

```
libcurl-unity/
├── deps/                       # Dependency sources (git submodules)
│   ├── curl/                   #   libcurl
│   ├── openssl/                #   OpenSSL
│   ├── nghttp2/                #   HTTP/2
│   ├── nghttp3/                #   HTTP/3
│   ├── ngtcp2/                 #   QUIC
│   └── zlib/                   #   zlib
├── bridge/                     # C bridge layer
│   ├── curl_unity_bridge.c     #   Variadic function wrappers
│   └── exports.def             #   Windows DLL export definitions
└── scripts/                    # Build scripts & utilities
    ├── build.sh                #   Main build script (macOS/iOS/Android)
    ├── build-windows.bat       #   Windows build script (MSVC)
    └── ...
```

## Building

### Requirements

* **macOS/iOS/Android**: macOS (Apple Silicon), Xcode 15+, CMake, Ninja
* **Android**: Android NDK required (via `ANDROID_NDK_HOME` or automatic detection)
* **Windows**: Windows build environment with MSVC (Visual Studio 2017+), CMake, Ninja, and Perl

### Quick Start

```bash
# Build all platforms
./scripts/build-macos.sh            # macOS ARM64 + x86_64 → universal binary
./scripts/build-ios.sh              # iOS ARM64 static library
./scripts/build-android.sh          # Android armv7 + arm64 + x86_64
scripts\build-windows-x64.bat       # Windows x64
scripts\build-windows-x86.bat       # Windows x86
```

## References

- [4AVolcano/curl-unity](https://github.com/4AVolcano/curl-unity)
