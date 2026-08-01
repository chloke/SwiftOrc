# Release checklist

Run these gates before tagging 0.1.0:

```sh
xcrun swift-format lint --recursive Sources Tests Examples
swift test -Xswiftc -warnings-as-errors
swift test --enable-code-coverage
swift build -c release -Xswiftc -warnings-as-errors
git diff --check
```

Then verify:

- the repository contains the intended open-source license and package metadata;
- every public type and behavior added for the milestone is documented;
- the README quick start still needs only `Workflow`, a state, and one node;
- all optional provider products build without third-party dependencies;
- traces, checkpoints, errors, and router reports contain no prompt or output;
- examples use only mock or local providers unless clearly configured otherwise;
- supported platform minimums match `Package.swift`;
- `CHANGELOG.md` describes the public surface and known limitations;
- the release commit is clean and the `0.1.0` tag points to that commit.

Do not tag while generated Xcode user data, credentials, build products, local
checkpoints, or temporary artifacts are tracked.
