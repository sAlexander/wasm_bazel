# wasm_bazel

A simple set of bazel rules and macros to build web assembly files with the Emscripten compiler.

Caveats (and TODOs):

 - Only works on linux
 - Only tested on relatively simple examples

# Usage

_file: WORKSPACE_
```
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "wasm_bazel",
    urls = [{ LATEST RELEASE URL FOR THIS REPO }],
    strip_prefix = "wasm_bazel-{RELEASE VERSION NUMBER}",
)
load("@wasm_bazel//:deps.bzl", "wasm_bazel_dev_dependencies")
wasm_bazel_dev_dependencies()
```

_file: BUILD_
```
load("@wasm_bazel//:wasm.bzl", "cc_native_wasm_library", "cc_native_wasm_binary")

# Defines both a cc_library for the host system and a wasm_library for web assembly.
cc_native_wasm_library(
  name = "library",
  ...
)

# Defines both a cc_binary for the host system and a wasm_binary for web assembly.
#
# wasm_biniary will output two files that are generated by Emscripten:
#  - binary-wasm.js
#  - binary-wasm.wasm
# 
# See Emscripten for more details.
cc_native_wasm_library(
  name = "binary",
  deps = [
      ":library",
  ],
  ...
)
```

See a working example in the examples directory.

# License

Licensed under MIT (see LICENSE).
