# SwiftOrcDemo

This iOS and macOS application presents focused examples of the framework's
features. It is an example catalog, not the required starting point for using
`SwiftOrc`.

Open `SwiftOrcDemo.xcodeproj`, select the `SwiftOrcDemo` scheme, and run on an
eligible device or Mac with Apple Intelligence enabled.

## Calculator Pipeline

Open **Calculator Pipeline** to inspect the original framework workflow as its
own focused tool-calling example:

```text
generate -> validate -> inspect (parallel) -> quality-check -> finalize
    |          |                                     |
    |          +--> retry                            +-------> review
    |
    +-------------------------------> fallback
```

- Typed schema-guided model output.
- Apple Foundation Models with a deterministic fallback.
- Developer-declared route capabilities.
- A typed calculator tool with automatic low-risk authorization.
- Validation, retries, timeout, and recovery.
- Parallel state inspection with deterministic merging.
- Reusable namespaced workflow components.
- Structured tracing and routing annotations.
- JSON checkpoints and resume support.

The page starts with a two-step arithmetic request. **Reset example** restores
it after editing. The calculator is classified as minimal-risk local math, so
the app authorizes it without showing an unexpected approval prompt. The trace
reports tool lifecycle events without arguments or outputs.

The app distinguishes `.completed` runs from `.recovered` runs. Cancelling or
terminating execution leaves the latest safe-boundary checkpoint in Application
Support; **Resume saved** continues with the same execution identifier, state,
step, retry attempt, event history, and recovery history.

The demo declares Apple's route as supporting text, structured output, and tool
calling. Its static fallback leaves capabilities unspecified because it returns
a deterministic schema-compatible response rather than interpreting the model
request.

## PDF Knowledge

Open **PDF Knowledge** to choose a selectable-text PDF and ask questions whose
answers must remain grounded in that document:

```text
choose PDF -> bounded PDFKit extraction -> page-aware chunks
    -> local keyword retrieval -> evidence branch
    -> on-device structured answer -> citation and quality checks in parallel
    -> approve, bounded revision, or safe stop
```

The app reads the file through the system document picker, holds extracted
passages in memory, and does not upload the document. Local retrieval sends only
the best matching passages to `AppleFoundationModel` with an `.onDeviceOnly`
routing policy. Text inside the PDF is explicitly marked as untrusted source
material so embedded instructions are not treated as workflow directions.

The model generates only the answer and an insufficient-evidence decision. It
does not have to reproduce internal passage identifiers or citation metadata.
Swift attaches the retrieved passage identifiers and page numbers to the result,
then checks those application-owned references before displaying their source
text. If the model is unavailable, the app clearly shows the most relevant
verbatim passages instead of presenting them as a generated answer. If local
search finds no evidence, the workflow stops without asking the model to guess.

This first demo intentionally favors a small, inspectable implementation over a
full RAG stack. It supports PDFs up to 20 MB, 250 pages, 1.5 million extracted
characters, and 1,500 passages. Password-protected files and image-only scans
are rejected; OCR, embeddings, persistence, and remote providers are outside
this example.

## Support Desk

Open **Support Desk** to try a local-first customer-support workflow using three
bundled mock tickets, mock account context, and a small in-process knowledge
base:

```text
select ticket -> load app-owned triage -> generate a structured reply
    -> check grounding, priority, sensitive claims, and reply quality in parallel
    -> revise if needed or use the bundled safe reply
    -> route to ordinary agent review or a required human decision
```

Application code supplies the category, priority, requested action, eligible
knowledge, internal note, and human-review policy for each mock ticket. Apple's
on-device model has one focused task: draft the editable customer reply from the
provided facts. Swift then checks grounding, prohibited claims, reply quality,
and the policy-owned triage fields. A refund, account change, or security
decision is never represented as automatically completed.

The customer message is explicitly treated as untrusted content inside the
model request. If Apple's model is unavailable, or its drafts repeatedly fail
the bounded validation loop, the workflow uses a bundled safe reply and runs it
through the same checks and branch policy. The final action is simulated: this
example neither sends a message nor mutates an account.

## Pantry Rescue

Open **Pantry Rescue** to try a product-style, offline-first workflow built from
real SwiftUI controls and bundled mock pantry data:

```text
select pantry -> set preferences -> generate structured recipe
    -> check pantry, allergies, time, and equipment in parallel
    -> approve or request a bounded revision
    -> present the checked meal and cooking steps
```

Apple's on-device model proposes the title, explanation, ingredient identifiers,
and cooking steps. Ordinary Swift remains authoritative about the selected
inventory, known allergens, allowed equipment, cooking-time limit, required
fields, and retry bound. The result screen is reachable only after those checks
pass.

If Apple's model is unavailable or repeatedly fails, the workflow records a
recovery transition and uses a bundled in-process recipe before running the same
deterministic checks. This keeps the example testable without a network
connection while clearly identifying the fallback in the developer disclosure.
The app never sends pantry data or preferences to a remote service.

The three consumer-facing screens intentionally hide orchestration terminology.
Developers can expand **How this plan was checked** on the result screen to
inspect the model node, parallel validation, revision branch, and fallback
events.

## Pocket Story Studio

Open **Pocket Story Studio** from the first screen to try a complete local-only
app scenario rather than a single framework feature. A one- or two-sentence idea
passes through this graph:

```text
validate idea -> plan five beats
    -> write part 1 -> duplicate check -> safety review -> accept or bounded rewrite
    -> write parts 2-5 with continuity notes and the same review loop
    -> review the complete story -> assemble continuous prose
```

Every model request uses `AppleFoundationModel` with an `.onDeviceOnly` routing
policy. There is intentionally no remote or static content fallback: when the
system model is unavailable or the output cannot pass the bounded quality and
safety path, the UI shows a neutral safe-stop message instead of a story.

The model returns typed plans, passages, continuity notes, and safety decisions.
Swift code enforces the five-beat structure, length constraints, retry limits,
routing, duplicate detection, and final assembly. A deterministic five-word
shingle comparison rejects a repeated newer passage while leaving the accepted
original intact, then requests a bounded replacement. Accepted passages are
joined deterministically, so the model never gets a final opportunity to replace
the ending with a summary.
The page also makes clear that automated content review reduces risk but is not
a guarantee of child suitability.

## Model-version compatibility example

Open **Model-version and fallback example** from the demo's first screen. This
second workflow shows how an app can select a task implementation that it has
validated for a particular Apple system-model generation:

```text
select-model-version
    |-- 27.x available ------> task-v27
    |-- 26.4-26.x available -> task-v26
    `-- otherwise -----------> fallback router
                                  |-- permitted mock remote
                                  `-- bundled static copy
```

Simulation mode uses only `ClosureLanguageModel` and `StaticLanguageModel`.
The route named `mock-remote` is classified as `.remote` so routing policy treats
it exactly like an external provider, but its implementation runs in-process and
never creates a network connection. It can be configured to succeed or fail.

Live mode replaces the simulated local provider with `AppleFoundationModel` and
uses its real availability. The external route remains simulated. Selecting an
older model generation in simulation verifies graph selection and fallback; it
does not reproduce older Apple weights on a newer OS.

The example deliberately keeps compatibility declarations in app state. The
framework selects and traces the route, while the application remains
authoritative about which prompt or component it has evaluated for each model
generation and whether network fallback is allowed.

## Learn one feature at a time

The repository documentation separates optional concepts:

- [Quick start](../../README.md)
- [Language models and routing](../../Documentation/LanguageModels.md)
- [Model tools and approvals](../../Documentation/Tools.md)
- [Reliability and checkpoints](../../Documentation/Reliability.md)
- [Scope and complexity budget](../../Documentation/ScopeAndComplexity.md)

Side-effecting nodes should be idempotent because a node interrupted before the
next checkpoint can execute again after resume.
