# vim: set expandtab:
# vim: set tabstop=2:

# TODO: Add support for other cc_(library|binary) arguments to wasm_(library|binary).

COMPILATION_MODE_FLAGS = {
    "opt": ["-O2", "-DNDEBUG"],
    "fastbuild": ["-gmlt"],
    "dbg": ["-g"],
}

def cc_native_wasm_library(name, deps = [], **kwargs):
    """Creates a cc_library ("name") and a wasm_library ("name-wasm")."""
    native.cc_library(
        name = name,
        deps = deps,
        **kwargs
    )

    wasm_library(
        name = "%s-wasm" % name,
        deps = ["%s-wasm" % dep for dep in deps],
        **kwargs
    )

def cc_native_wasm_binary(name, deps = [], bind = False, modularize = False, **kwargs):
    """Creates a cc_binary ("name") and a wasm_binary ("name-wasm")."""
    native.cc_binary(
        name = name,
        deps = deps,
        **kwargs
    )

    wasm_binary(
        name = "%s-wasm" % name,
        deps = ["%s-wasm" % dep for dep in deps],
        bind = bind,
        modularize = modularize,
        **kwargs
    )

WasmInfo = provider(
    "Info needed to compile/link c++ using the emscripten compiler.",
    fields = {
        "hdrs": "depset of header Files from transitive dependencies.",
        "objs": "depset of Files from compilation.",
        "linkopts": "A set of linker options to use in the link command.",
        "includes": "A set of include directives for every compile and link command",
    },
)

WasmBinaryInfo = provider(
    "Information about the produced wasm binary files.",
    fields = {
        "js": "the javascript file produced.",
        "wasm": "the wasm file produced.",
    },
)

def _flatten(array):
    return [out for entry in array for out in entry]

def _extract_and_flatten(array, pos):
    return [out for entry in array for out in entry[pos]]

def _compile(ctx, binary = False):
    """Compiles all of the srcs as a library, and then optionally creates a binary (binary == True).

    For library: returns [DefaultInfo, WasmInfo].
    For binary: returns [DefaultInfo].
    """
    transitive_hdrs = [dep[WasmInfo].hdrs for dep in ctx.attr.deps]
    transitive_objs = [dep[WasmInfo].objs for dep in ctx.attr.deps]

    linkopts = ctx.attr.linkopts + _flatten([dep[WasmInfo].linkopts for dep in ctx.attr.deps])
    includes = [
        "{root}/{path}".format(root = ctx.label.workspace_root, path = i)
        for i in ctx.attr.includes
    ] + _flatten([dep[WasmInfo].includes for dep in ctx.attr.deps])

    tool_deps = ctx.attr._compiler.default_runfiles.files

    hdrs = depset(ctx.files.hdrs, transitive = transitive_hdrs)

    # For input srcs, compile multiple times, one for each src.
    # in: [src]
    # out: [src.o]
    mnemonic_ins_outs = [("EmccCompileLibrary", depset([src]), [ctx.actions.declare_file(src.path + ".o")]) for src in ctx.files.srcs]

    if binary:
        # For binary builds, compile again with all objects, including transitive.
        # in: srcs.o + transitive_srcs.o
        # out: name.js, name.wasm
        library_objs = _extract_and_flatten(mnemonic_ins_outs, 2)
        binary_inputs = depset(library_objs, transitive = transitive_objs)

        out_js = ctx.actions.declare_file(ctx.label.name + ".js")
        out_wasm = ctx.actions.declare_file(ctx.label.name + ".wasm")
        binary_outputs = [out_js, out_wasm]

        mnemonic_ins_outs.append(("EmccLinkBinary", binary_inputs, binary_outputs))

    for mnemonic, inputs, outputs in mnemonic_ins_outs:
        all_inputs = depset(transitive = [inputs, hdrs, tool_deps])

        compilation_mode = ctx.var["COMPILATION_MODE"]
        if compilation_mode not in COMPILATION_MODE_FLAGS:
            fail("Unknown compilation mode: " + compilation_mode)
        compilation_mode_flags = COMPILATION_MODE_FLAGS[compilation_mode]

        args = ctx.actions.args()
        args.add_all(inputs.to_list())
        args.add("-o", outputs[0])
        args.add_all(ctx.attr.copts)
        args.add_all(ctx.fragments.cpp.cxxopts)
        args.add_all(ctx.fragments.cpp.copts)
        args.add_all(compilation_mode_flags)
        args.add_all(_flatten(zip(["-isystem"] * len(includes), includes)))
        if mnemonic == "EmccCompileLibrary":
            # For library, we want to build the intermediate .o file.
            args.add("-c")
        if mnemonic == "EmccLinkBinary":
            if ctx.attr.bind:
                args.add("--bind")
            if ctx.attr.modularize:
                args.add("-s", "MODULARIZE=1")
            args.add_all(linkopts)
        args.add("-I.")

        ctx.actions.run(
            mnemonic = mnemonic,
            executable = ctx.executable._compiler,
            tools = [ctx.executable._compiler],
            arguments = [args],
            inputs = all_inputs,
            outputs = outputs,
            env = {
                # TODO: Remove this cache -- it bypasses the bazel build process
                # and will cause problems (for example, the cache will not be
                # cleaned when we switch from -c opt to -c dbg, and we will get unexpected results).
                "EM_CACHE": "/tmp/.cache",
            },
        )

    objs = _extract_and_flatten(mnemonic_ins_outs, 2)

    rval = []

    # For library and binary, we produce DefaultInfo.
    rval.append(DefaultInfo(files = depset(objs)))

    if binary:
        # For binary, we produce WasmBinaryInfo.
        rval.append(WasmBinaryInfo(js = out_js, wasm = out_wasm))
    else:
        # For library, we produce WasmInfo.
        rval.append(WasmInfo(hdrs = hdrs, objs = depset(objs, transitive = transitive_objs), linkopts = linkopts, includes = includes))

    return rval

def _wasm_binary_impl(ctx):
    return _compile(ctx, binary = True)

def _wasm_library_impl(ctx):
    return _compile(ctx, binary = False)

# Generates a web assembly library using Emscripten.
#
# wasm_library will generate one file for use as a dep in wasm_binary:
#   - $(name).o
#
# All of the dep inputs are expected to be other wasm_library labels.
wasm_library = rule(
    implementation = _wasm_library_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "hdrs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [WasmInfo]),
        "copts": attr.string_list(default = []),
        "linkopts": attr.string_list(default = []),
        "includes": attr.string_list(default = []),
        "_compiler": attr.label(
            default = Label("@wasm_binaries//:emcc"),
            executable = True,
            cfg = "exec",
        ),
    },
    fragments = ["cpp"],
)

# Generates a webassembly binary using Emscripten.
#
# wasm_binary will output two files that are generated by Emscripten:
#  - $(name).js
#  - $(name).wasm
# See Emscripten for more details about each file.
#
# All of the dep inputs are expected to be other wasm_library labels.
wasm_binary = rule(
    implementation = _wasm_binary_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "hdrs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [WasmInfo]),
        "copts": attr.string_list(default = []),
        "linkopts": attr.string_list(default = []),
        "includes": attr.string_list(default = []),
        "bind": attr.bool(default = False, doc = "Link in the embind library"),
        "modularize": attr.bool(default = False, doc = "Pass -s MODULARIZE=1 to emcc to create an es6 module."),
        "_compiler": attr.label(
            default = Label("@wasm_binaries//:emcc"),
            executable = True,
            cfg = "exec",
        ),
    },
    fragments = ["cpp"],
)

def _wasm_extract_impl(ctx):
    key = ctx.attr._extract
    obj = getattr(ctx.attr.src[WasmBinaryInfo], key)
    return [DefaultInfo(files = depset([obj]))]

# Extracts the js or wasm file from a wasm_binary.
wasm_extract_js = rule(
    implementation = _wasm_extract_impl,
    attrs = {
        "src": attr.label(providers = [WasmBinaryInfo]),
        "_extract": attr.string(default = "js"),
    },
)
wasm_extract_wasm = rule(
    implementation = _wasm_extract_impl,
    attrs = {
        "src": attr.label(providers = [WasmBinaryInfo]),
        "_extract": attr.string(default = "wasm"),
    },
)
