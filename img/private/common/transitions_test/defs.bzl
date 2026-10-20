"""Analysis tests for sharing a base index across image platform transitions."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//img:image.bzl", "image_index", "image_manifest")
load("//img:layer.bzl", "image_layer")

_BASE_INDEX = Label(":base_index")
_PLATFORMS = "//command_line_option:platforms"

_ConfigurationsInfo = provider(
    doc = "Tracks the actual configurations of an index and its transitive base index.",
    fields = {
        "base_configurations": "Configurations of base_index reached along the image dependencies.",
        "configuration": "Configuration of this target.",
    },
)

def _collect_configurations_impl(target, ctx):
    base_configurations = [ctx.configuration] if target.label == _BASE_INDEX else []
    for name in ["manifests", "base"]:
        dependencies = getattr(ctx.rule.attr, name, [])
        if dependencies == None:
            continue
        if type(dependencies) != "list":
            dependencies = [dependencies]
        for dependency in dependencies:
            base_configurations.extend(dependency[_ConfigurationsInfo].base_configurations)
    return [_ConfigurationsInfo(
        base_configurations = base_configurations,
        configuration = ctx.configuration,
    )]

_collect_configurations = aspect(
    implementation = _collect_configurations_impl,
    attr_aspects = ["manifests", "base"],
)

def _shared_base_index_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[_ConfigurationsInfo]
    configurations = []
    for configuration in info.base_configurations:
        if configuration not in configurations:
            configurations.append(configuration)
    asserts.equals(env, ctx.attr.expected_paths, len(info.base_configurations), "All manifest branches must reach the base index")
    asserts.equals(env, 1, len(configurations), "The base index must exist in exactly one configuration")
    for configuration in configurations:
        asserts.equals(env, info.configuration, configuration, "The base index must restore the outer index's configuration")
    return analysistest.end(env)

_shared_base_index_test = analysistest.make(
    _shared_base_index_test_impl,
    attrs = {"expected_paths": attr.int(mandatory = True)},
    config_settings = {_PLATFORMS: [str(Label(":outer_platform"))]},
    extra_target_under_test_aspects = [_collect_configurations],
)

def platform_transitions_test_suite(name):
    """Creates real nested images and analysis tests that only build test scripts.

    Args:
        name: Name of the wrapping test suite.
    """

    # A distinct outer label makes both image branches transition on every host.
    # Its constraints do not need to match the host: no image actions execute.
    native.platform(
        name = "outer_platform",
        constraint_values = ["@platforms//os:osx", "@platforms//cpu:aarch64"],
    )
    native.platform(
        name = "linux_amd64",
        constraint_values = ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    )
    native.platform(
        name = "linux_arm64",
        constraint_values = ["@platforms//os:linux", "@platforms//cpu:aarch64"],
    )

    image_manifest(name = "base_manifest", tags = ["manual"])
    image_index(
        name = "base_index",
        manifests = [":base_manifest"],
        platforms = [":linux_amd64", ":linux_arm64"],
        tags = ["manual"],
    )
    image_layer(
        name = "application_layer",
        srcs = {"app": ":app.txt"},
        tags = ["manual"],
    )

    tests = []
    for case, platform, platforms in [
        ("inherited", None, [":linux_amd64", ":linux_arm64"]),
        ("explicit_same", ":linux_amd64", [":linux_amd64"]),
        ("explicit_override", ":linux_amd64", [":linux_arm64"]),
    ]:
        # Explicit manifests exercise an already-matching platform and an
        # arm64 -> amd64 override, each of which must preserve the outer origin.
        image_manifest(
            name = case + "_manifest",
            base = ":base_index",
            layers = [":application_layer"],
            platform = platform,
            tags = ["manual"],
        )
        image_index(
            name = case + "_index",
            manifests = [":" + case + "_manifest"],
            platforms = platforms,
            tags = ["manual"],
        )
        test_name = case + "_base_index_test"
        _shared_base_index_test(
            name = test_name,
            target_under_test = ":" + case + "_index",
            expected_paths = len(platforms),
            size = "small",
        )
        tests.append(":" + test_name)
    native.test_suite(name = name, tests = tests)
