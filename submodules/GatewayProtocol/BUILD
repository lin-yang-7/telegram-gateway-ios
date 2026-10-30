load("@protobuf//bazel:proto_library.bzl", "proto_library")
load("@build_bazel_rules_swift//proto:proto.bzl", "swift_proto_library")

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
        "@build_bazel_rules_swift//proto/compilers:swift_proto",
        "@build_bazel_rules_swift//proto/compilers:swift_client_proto",
    ],
    module_name = "GatewaySessionClient",
    protos = [":GatewaySessionProto"],
    visibility = ["//visibility:public"],
)
