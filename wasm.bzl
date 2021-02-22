# vim: set expandtab:
# vim: set tabstop=2:

# TODO: Add support for other cc_(library|binary) arguments to wasm_(library|binary).

def cc_native_wasm_library(name, deps=[], **kwargs):
  """Creates a cc_library ("name") and a wasm_library ("name-wasm")."""
  native.cc_library(
      name=name,
      deps=deps,
      **kwargs)

  wasm_library(
      name="%s-wasm" % name,
      deps=["%s-wasm" % dep for dep in deps],
      **kwargs)

def cc_native_wasm_binary(name, deps=[], **kwargs):
  """Creates a cc_binary ("name") and a wasm_binary ("name-wasm")."""
  native.cc_binary(
      name=name,
      deps=deps,
      **kwargs)

  wasm_binary(
      name="%s-wasm" % name,
      deps=["%s-wasm" % dep for dep in deps],
      **kwargs)

WasmInfo = provider(
  "Info needed to compile/link c++ using the emscripten compiler.",
  fields={
    "hdrs": "depset of header Files from transitive dependencies.",
    "objs": "depset of Files from compilation.",
  })

WasmBinaryInfo = provider(
  "Information about the produced wasm binary files.",
  fields={
    "js": "the javascript file produced.",
    "wasm": "the wasm file produced.",
  },
)

def _extract_and_flatten(array, pos):
  return [out for entry in array for out in entry[pos]]

def _compile(ctx, binary=False):
  """Compiles all of the srcs as a library, and then optionally creates a binary (binary == True).

  For library: returns [DefaultInfo, WasmInfo].
  For binary: returns [DefaultInfo].
  """
  transitive_hdrs = [dep[WasmInfo].hdrs for dep in ctx.attr.deps]
  transitive_objs = [dep[WasmInfo].objs for dep in ctx.attr.deps]

  tool_deps = ctx.attr._compiler.default_runfiles.files

  hdrs = depset(ctx.files.hdrs, transitive=transitive_hdrs)

  # For input srcs, compile multiple times, one for each src.
  # in: [src]
  # out: [src.o]
  mnemonic_ins_outs = [("EmccCompileLibrary", depset([src]), [ctx.actions.declare_file(src.path + ".o")]) for src in ctx.files.srcs]

  if binary:
    # For binary builds, compile again with all objects, including transitive.
    # in: srcs.o + transitive_srcs.o
    # out: name.js, name.wasm
    library_objs = _extract_and_flatten(mnemonic_ins_outs, 2)
    binary_inputs = depset(library_objs, transitive=transitive_objs)

    out_js = ctx.actions.declare_file(ctx.label.name + ".js")
    out_wasm = ctx.actions.declare_file(ctx.label.name + ".wasm")
    binary_outputs = [out_js, out_wasm]

    mnemonic_ins_outs.append(("EmccLinkBinary", binary_inputs, binary_outputs))

  for mnemonic, inputs, outputs in mnemonic_ins_outs:
    all_inputs = depset(transitive=[inputs, hdrs, tool_deps])

    args = ctx.actions.args()
    args.add_all(inputs.to_list())
    args.add("-o", outputs[0])
    if mnemonic == "EmccCompileLibrary":
      # For library, we want to build the intermediate .o file.
      args.add("-c")
    args.add("-I.")

    ctx.actions.run(
        mnemonic=mnemonic,
        executable = ctx.executable._compiler,
        arguments = [args],
        inputs = all_inputs,
        outputs = outputs,
        env = {
        "EM_CACHE": "/tmp/.cache",
        },
      )
  
  objs = _extract_and_flatten(mnemonic_ins_outs, 2)

  rval = []

  # For library and binary, we produce DefaultInfo.
  rval.append(DefaultInfo(files=depset(objs)))

  if binary:
    # For binary, we produce WasmBinaryInfo.
    rval.append(WasmBinaryInfo(js=out_js, wasm=out_wasm))
  else:
    # For library, we produce WasmInfo.
    rval.append(WasmInfo(hdrs = hdrs, objs = depset(objs, transitive=transitive_objs)))

  return rval


def _wasm_binary_impl(ctx):
  return _compile(ctx, binary=True)

def _wasm_library_impl(ctx):
  return _compile(ctx, binary=False)

wasm_library = rule(
  implementation = _wasm_library_impl,
  attrs = {
    "srcs": attr.label_list(allow_files = True),
    "hdrs": attr.label_list(allow_files = True),
    "deps": attr.label_list(providers = [WasmInfo]),
    "_compiler": attr.label(
    default = Label("@wasm-binaries//:emcc"),
        executable = True,
        cfg = "exec",),
  }
)

wasm_binary = rule(
  implementation = _wasm_binary_impl,
  attrs = {
    "srcs": attr.label_list(allow_files = True),
    "hdrs": attr.label_list(allow_files = True),
    "deps": attr.label_list(providers = [WasmInfo]),
    "_compiler": attr.label(
    default = Label("@wasm-binaries//:emcc"),
        executable = True,
        cfg = "exec",),
  }
)
