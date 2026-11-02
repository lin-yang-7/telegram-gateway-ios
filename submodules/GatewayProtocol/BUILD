load("@protobuf//bazel:proto_library.bzl", "proto_library")
load("@build_bazel_rules_swift//proto:proto.bzl", "swift_proto_library")
load("@build_bazel_rules_swift//proto:swift_proto_compiler.bzl", "swift_proto_compiler")
load(
    "@build_bazel_rules_swift//proto/compilers:swift_proto_compiler_macros.bzl",
    "GRPC_PLUGIN_OPTION_ALLOWLIST",
    "PROTO_PLUGIN_OPTION_ALLOWLIST",
    "PROTO_PLUGIN_OPTIONS",
)

# `rules_swift` fetches its own copies of `com_github_apple_swift_protobuf`,
# `com_github_grpc_grpc_swift` and `com_github_apple_swift_nio` (for its built-in
# proto compilers), while the main module also fetches them for
# `//submodules/TelegramCore`. Both copies are separate repositories, and a
# `swift_library` depending on both ends up passing two module maps that define
# the same C modules ("Redefinition of module 'CNIOLinux'", 'CGRPCZlib', ...),
# which clang rejects.
#
# Using the main module's plugin binaries and dependency labels here keeps the
# generated code on the main module's copies, so only one set is ever in the
# same compilation.
swift_proto_compiler(
    name = "swift_proto",
    deps = [
        "@com_github_apple_swift_protobuf//:SwiftProtobuf",
    ],
    plugin = "@com_github_apple_swift_protobuf//:ProtoCompilerPlugin",
    plugin_name = "swift",
    plugin_option_allowlist = PROTO_PLUGIN_OPTION_ALLOWLIST,
    plugin_options = PROTO_PLUGIN_OPTIONS,
    suffixes = [".pb.swift"],
)

swift_proto_compiler(
    name = "swift_client_proto",
    deps = [
        "@com_github_apple_swift_protobuf//:SwiftProtobuf",
        "@com_github_grpc_grpc_swift//:GRPC",
    ],
    plugin = "@com_github_grpc_grpc_swift//:protoc-gen-grpc-swift",
    plugin_name = "swift_client",
    plugin_option_allowlist = GRPC_PLUGIN_OPTION_ALLOWLIST,
    plugin_options = {
        "Client": "true",
        "Server": "false",
        "TestClient": "false",
        "Visibility": "Public",
    },
    suffixes = [".grpc.swift"],
)

# Keep this schema compatible with gateway/api/gateway/v1/gateway_session.proto.
# Bazel generates the client at build time; generated Swift sources are not
# committed.
proto_library(
    name = "GatewaySessionProto",
    srcs = ["gateway_session.proto"],
    visibility = ["//visibility:public"],
)

swift_proto_library(
    name = "GatewaySessionClient",
    compilers = [
        ":swift_proto",
        ":swift_client_proto",
    ],
    module_name = "GatewaySessionClient",
    protos = [":GatewaySessionProto"],
    visibility = ["//visibility:public"],
)
