# Projection

Projection is an Elixir-authoritative UI architecture for embedded and desktop-native apps.

Elixir owns state, behavior, routing, validation, and side effects. A Rust + Slint host renders a projection of that state and forwards user intents back to Elixir.

Projection is intentionally lightweight. It targets simple, reliable UIs for embedded devices and can also run on desktop for local development/testing.

It is not a full Phoenix LiveView replacement and currently omits many advanced LiveView concepts.

Canonical rule:
`Elixir owns truth. Slint renders a projection of that truth. The Rust host only bridges the two.`

## Design Summary

- Keep domain logic in Elixir.
- Keep rendering/input in Slint.
- Keep Rust policy-free.
- Move data via `render` + incremental `patch` envelopes, not imperative UI commands.

## Architecture

There are two event loops:

- Elixir session loop (`Projection.Session`): authoritative state machine.
- Slint UI loop: input, redraw, windowing.

Rust bridges them:

- reader/writer threads handle framed JSON on stdin/stdout.
- UI mutations happen on the Slint UI thread.
- UI host enforces monotonic `rev` (`render` must be newer, `patch` must be `last_rev + 1`).
- On `sid`/`rev` mismatch, UI host requests resync with `ready`.

Transport uses OTP ports with `{:packet, 4}` framing.

## Project Layout

- `lib/projection/`: protocol, patching, router, session runtime.
- `lib/projection_ui/`: screen behavior/state, session supervisor, port owner.
- `lib/projection_ui/screens/`: Slint app shell/layout/templates.
- `slint/ui_host/`: Rust UI host, protocol bridge, generated Rust setters/dispatch.
- `planning/`: local planning notes and milestone docs (gitignored).

## Quick Start

Prerequisites:

- Elixir + Mix
- Rust + Cargo

Install/build/run:

```bash
mix deps.get
mix compile
mix ui.preview --backend winit --tick-ms 250
```

Useful commands:

```bash
mix projection.codegen
mix test
cargo check --manifest-path slint/ui_host/Cargo.toml
```

## Compile Pipeline

`mix compile` runs custom compilers from `mix.exs`:

1. `mix projection.codegen`
2. `cargo build` for `slint/ui_host`
3. copy UI host binary to `priv/ui_host/ui_host`

## Routing DSL

Routes are defined in Elixir with `screen_session` + `screen`:

```elixir
defmodule Projection.Router do
  use Projection.Router.DSL

  alias ProjectionUI.Screens.Clock
  alias ProjectionUI.Screens.Devices

  screen_session :main do
    screen "/clock", Clock, :show
    screen "/devices", Devices, :index
  end

  screen_session :admin do
    screen "/admin", Clock, :index, as: :admin
  end
end
```

Generated Elixir helpers include:

- `Projection.Router.route_name(:clock)` -> `"clock"`
- `Projection.Router.route_path(:clock)` -> `"/clock"`
- `Projection.Router.route_keys/0`
- `Projection.Router.route_names/0`

## Screen Model

Screen modules use `use ProjectionUI, :screen`.

Lifecycle callbacks are optional and have defaults:

- `mount/3`
- `handle_event/3`
- `handle_params/2`
- `handle_info/2`
- `subscriptions/2`
- `render/1`

State model:

- `state`: mutable `ProjectionUI.State` (assigns map).
- `session`: immutable per-session context.
- `params`: route/navigation parameters.

## Schema DSL

Define typed screen VM fields with `schema do ... end`:

```elixir
defmodule ProjectionUI.Screens.Example do
  use ProjectionUI, :screen

  schema do
    field :title, :string, default: "Hello"
    field :count, :integer, default: 0
  end
end
```

Supported scalar types are `:string`, `:bool`, `:integer`, and `:float`.

## Binding Modes

- Typed scalar bindings: declare fields in `schema`, codegen emits Rust setters/patch dispatch.
- Dynamic VM lookups: use `vm_text` / `vm_list_*` callbacks for richer structures (for example list tables) until typed `id_table` support lands.

This split is intentional for now: scalar contract is strict; collection-heavy UIs still use generic path lookups.

## UI Intent Conventions

Generic callback:

- `ui_intent(intent_name, intent_arg)`

Screen contract:

- Handle events in `handle_event/3`; unhandled events can no-op.

Routing callback:

- `navigate(route_name, params_json)`

Payload mapping in Rust:

- empty `intent_arg` -> `%{}`
- non-empty `intent_arg` -> `%{"arg" => "..."}`
- `navigate(...)` -> `ui.route.navigate` with `%{"to" => route_name, "params" => parsed_json_object}`

## Generated Artifacts

Generated from Elixir source-of-truth (do not edit manually):

- `slint/ui_host/src/generated/*.rs` from screen schema metadata
- `slint/ui_host/src/generated/routes.slint` from router metadata

`app.slint` imports the generated Slint routes global from `slint/ui_host/src/generated/routes.slint` so route names are centralized in router definitions.

## Manual Smoke Test

1. Run `mix ui.preview --backend winit --tick-ms 250`.
2. Confirm window opens and clock updates.
3. Use top nav to switch `Clock` and `Devices`.
4. In `Clock`, change timezone and verify text updates.
5. In `Clock`, click Pause/Resume and verify behavior.
6. Stop Elixir and verify Slint host exits.

## Planning Docs

Local-only planning docs live under `planning/` and are gitignored.
