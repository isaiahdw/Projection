# Projection

Projection is a lightweight UI architecture for embedded-style apps where Elixir is authoritative and Slint is the renderer.

`Elixir owns truth. Slint renders a projection of that truth. Rust only bridges the two.`

## What this is for

Projection is built for UIs where reliability and predictable behavior matter more than rich browser features:

- Embedded and appliance-like interfaces
- Local/native rendering without a browser
- Clear separation between domain logic and rendering logic

Elixir handles state, workflows, routing, and side effects.  
Rust + Slint renders the current view-model and sends user intents back.

## How it works

There are two event loops:

1. Elixir session loop (`Projection.Session`) computes the authoritative VM.
2. Slint UI loop handles input and rendering.

The Rust host sits between them over an OTP Port (`{:packet, 4}`), using `render` and incremental `patch` envelopes.

Typical flow:

1. UI host sends `ready`.
2. Elixir replies with `render`.
3. UI interactions send `intent`.
4. Elixir updates state and emits minimal `patch` ops.
5. Rust applies patches on the Slint UI thread.

If revisions drift, the host requests resync with `ready`.

## Included demo

This repo includes a runnable demo with:

- `Clock` screen: ticking clock, pause/resume, timezone selection
- `Devices` screen: list rendering and row-level updates by stable ID
- Route navigation between screens
- Recoverable UI fallback when a screen render raises

## Screen model (Elixir)

Screens use `use ProjectionUI, :screen` and define a schema contract:

```elixir
defmodule ProjectionUI.Screens.Example do
  use ProjectionUI, :screen

  schema do
    field :title, :string, default: "Hello"
    field :count, :integer, default: 0
    field :meta, :map, default: %{}
  end
end
```

All screens declare `schema do ... end` (empty is allowed).

Supported schema types:

- Scalars: `:string | :bool | :integer | :float`
- Containers: `:map | :list`

Scalar fields are codegen-bound to Slint properties.  
Container fields are read via VM lookup callbacks (`vm_text`, `vm_list_*`).

## Getting started

Prerequisites:

- Elixir + Mix
- Rust + Cargo

Install/build/run demo:

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

## Repo map

- `lib/projection/`: session runtime, protocol, routing, patch logic
- `lib/projection_ui/`: screen behavior/schema/state and port supervision
- `lib/projection_ui/screens/`: Slint app shell + screen templates
- `slint/ui_host/`: Rust host, protocol bridge, generated bindings
