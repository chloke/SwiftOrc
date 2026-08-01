# Scope and complexity budget

`SwiftOrc` is infrastructure for predictable processes, not a collection
of AI product features.

## Core admission rules

A new core abstraction should satisfy every item:

1. It is useful in at least two materially different application domains.
2. It is provider-neutral or belongs in a provider adapter target.
3. Existing nodes and policies cannot express it clearly through composition.
4. It remains completely optional for applications that do not use it.
5. Omitting configuration has a safe, unsurprising default.
6. It can be tested deterministically without network access.
7. Its diagnostics can avoid sensitive prompts, arguments, outputs, and bytes.

Domain implementations such as image moderation, face detection, character
memory, lifecycle simulation, news retrieval, and image generation do not
belong in the core. They should be app nodes, reusable workflow components, or
separate packages.

## Public API budget

- Package plumbing used only by sibling targets uses `package` access.
- New public top-level types require a documented developer use case.
- Prefer extending an existing configuration value over adding parallel types.
- Do not add a convenience abstraction unless it removes concepts from the
  normal path rather than merely renaming them.
- The root README remains a quick-start, not an exhaustive reference.
- Advanced features receive focused guides and never become prerequisites.
- The package keeps zero third-party runtime dependencies unless a dependency
  replaces substantial maintained code and remains optional.

Public symbol count should not grow during a milestone without an explicit API
review. When it grows, the change should explain why composition was
insufficient and which real application scenarios need the new surface.

## Progressive learning contract

A developer should encounter concepts in this order:

1. `Workflow`, state, node, and `NodeResult`.
2. A model node when generation is needed.
3. Validation or recovery when failure behavior matters.
4. Routing only when multiple providers exist.
5. Tools, artifacts, approvals, or checkpoints only when the app requires them.

The first four concepts must remain enough to build and run a useful workflow.

## Review questions

Before merging a feature, ask:

- Can this be an example component instead of framework code?
- Can a developer ignore it without seeing new required configuration?
- Does it introduce another source of state or lifecycle?
- Does it make the simplest model request longer?
- Is the public type needed by application developers, or only by this package?
- Can an existing policy or node wrapper express the behavior?

If the answers reveal additional mandatory concepts, the design should be
simplified before implementation.

## Explicit 0.1 non-goals

The 0.1 line intentionally does not include:

- a general autonomous-agent or multi-agent runtime;
- prompt optimization, hidden chain-of-thought capture, or model evaluation;
- built-in RAG, vector databases, web search, or long-term conversational memory;
- domain moderation, image generation, OCR, face detection, or news services;
- a credential store, subscription system, or provider account UI;
- background-job scheduling or distributed workflow execution;
- durable interruption in the middle of an arbitrary node;
- automatic discovery of provider capabilities or model versions;
- historical Apple system-model selection.

Checkpointing remains node-boundary recovery. Tool approval is the one durable
human decision modeled directly because it has specific authorization and
redaction semantics. A future generic pause/resume mechanism belongs in a later
release only if real applications demonstrate a common state model that cannot
be expressed by explicit nodes and checkpoints.
