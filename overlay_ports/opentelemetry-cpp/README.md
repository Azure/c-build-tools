# OpenTelemetry C++ overlay

This overlays vcpkg's `opentelemetry-cpp` 1.29.0, port-version 1, retaining its
features and both upstream patches. On Windows with MSVC, it appends `/W3` to
the C and C++ compiler flags for the SDK and its exporters. Other ports and
non-MSVC builds are unchanged.

The upstream recipe does not set an MSVC warning level, so its SDK objects are
built at warning level 0 and trigger BinSkim BA2007
(`EnableCriticalCompilerWarnings`) when linked into applications. Changing the
overlay changes the vcpkg package ABI key, rebuilding the SDK rather than
reusing the previously cached binaries.

The recipe and patches come from microsoft/vcpkg commit
`9eec002df1cd109f8f104cd966a763daf9751489`. Keep the manifest, source hash,
recipe and patches in sync when updating vcpkg in consuming repositories.
Remove this overlay once a vcpkg update supplies the SDK and exporters built
at `/W3` or higher.
