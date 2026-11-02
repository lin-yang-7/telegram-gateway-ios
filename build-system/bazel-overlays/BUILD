# BUILD overlays for the WORKSPACE-era third-party archives declared in the root MODULE.bazel
# (SwiftNIO, gRPC, swift-protobuf, ...).
#
# These are copies of `build-system/bazel-rules/rules_swift/third_party/*/BUILD.overlay` with one
# change: they load the rules from `@build_bazel_rules_swift` instead of `@rules_swift`.
#
# Why a copy is needed: a repository created by a rule in the root MODULE.bazel resolves apparent
# repo names through the *root module's* mapping, where rules_swift is named
# `build_bazel_rules_swift` (see `bazel_dep(name = "rules_swift", repo_name = ...)`), so the
# upstream overlays - which use rules_swift's own name `@rules_swift` - fail with "No repository
# visible as '@rules_swift' from repository ...". bzlmod has neither `repo_mapping` on repository
# rules nor a second `bazel_dep` alias for the same module, and the vendored upstream overlays
# cannot be rewritten in place because rules_swift's *own* copies of these archives still load
# them through rules_swift's mapping, where only `@rules_swift` resolves.
#
# Keep these in sync with the vendored overlays when rules_swift is upgraded (same targets, only
# the rules_swift load label differs).

exports_files(
    glob(["*.BUILD"]),
    visibility = ["//visibility:public"],
)
