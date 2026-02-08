# Projection

Projection is an Elixir-authoritative UI runtime for native and embedded apps rendered by Slint.
It is for applications where you cannot or do not want to ship a browser runtime.

Projection is designed primarily for embedded UIs, and also runs well on macOS and Windows for local development and testing.

The design is heavily inspired by Phoenix LiveView: state and behavior stay in Elixir processes, while the client runtime renders and forwards intents.

`Elixir owns truth. Slint renders a projection of that truth. Rust bridges the two.`

This repository is the library core. It intentionally does not ship demo screens or a demo router.

> Note: This project is mostly AI-generated and is not yet hardened or tested for production systems.

## What it provides

- Session runtime (`Projection.Session`) for authoritative UI state.
- Port bridge runtime (`ProjectionUI.HostBridge`) for framed JSON envelopes over stdio.
- Router DSL (`Projection.Router.DSL`) for route-driven screen sessions.
- Schema DSL (`ProjectionUI.Schema`) for typed screen fields.
- Codegen (`mix projection.codegen`) for Rust/Slint typed bindings.
- Compile tasks (`mix compile.projection_codegen`, `mix compile.projection_ui_host`) that consumer apps can opt into.

## Install

Add Projection to your app dependencies:

```elixir
defp deps do
  [
    {:projection, "~> 0.1.0"}
  ]
end
```

## Starter generator

This repo also includes a companion Mix archive project at `projection_new/`.
It generates a ready-to-run Projection + Slint starter app (router, hello screen,
UI templates, and `ui_host` crate scaffold).

Build and install the archive locally:

```bash
cd projection_new
mix archive.build
mix archive.install
```

Generate a new app:

```bash
mix projection.new my_app
```

## Consumer setup

Projection codegen and ui_host build should run in the consumer project, not inside the dependency compile step.

In your app `mix.exs`, opt in to Projection compilers:

```elixir
def project do
  [
    app: :my_app,
    version: "0.1.0",
    elixir: "~> 1.19",
    compilers: Mix.compilers() ++ [:projection_codegen, :projection_ui_host],
    deps: deps()
  ]
end
```

In your app config:

```elixir
import Config

config :projection,
  otp_app: :my_app,
  router_module: MyApp.Router
```

Optional:

- `otp_apps: [:my_app, :my_app_web]` for multi-app module discovery.
- `screen_modules: [MyApp.Screens.Clock]` for explicit extra screen discovery.

Your app also owns the shared Slint shell files under `lib/projection_ui/ui/`:

- `app_shell.slint`
- `ui.slint`
- `screen.slint`
- `error.slint`

`mix projection.new` scaffolds these for you.

## Define a screen

```elixir
defmodule MyApp.Screens.Clock do
  use ProjectionUI, :screen

  schema do
    field :clock_text, :string, default: "--:--:--"
    field :clock_running, :bool, default: true
  end

  @impl true
  def handle_event("clock.pause", _payload, state) do
    {:noreply, assign(state, :clock_running, false)}
  end
end
```

## Define routes

```elixir
defmodule MyApp.Router do
  use Projection.Router.DSL

  screen_session :main do
    screen "/clock", MyApp.Screens.Clock, :show, as: :clock
  end
end
```

## Start a runtime session

```elixir
{:ok, _sup} =
  Projection.start_session(
    name: MyApp.ProjectionSupervisor,
    session_name: MyApp.ProjectionSession,
    host_bridge_name: MyApp.ProjectionHostBridge,
    router: MyApp.Router,
    route: "clock",
    command: "/path/to/ui_host"
  )
```

You must pass either:

- `:router` for routed mode, or
- `:screen_module` for single-screen mode.

## Protocol model

The bridge uses framed JSON envelopes (`{:packet, 4}`):

- UI -> Elixir: `ready`, `intent`
- Elixir -> UI: `render`, `patch`, `error`

Patches use an RFC 6902 subset (`replace`, `add`, `remove`).

## Build and test

```bash
mix deps.get
mix projection.codegen
mix compile
mix test
```

## Observability

Runtime logs include structured metadata:

- `sid`
- `rev`
- `screen`

Telemetry events:

- `[:projection, :session, :intent, :received]`
- `[:projection, :session, :render, :complete]`
- `[:projection, :session, :patch, :sent]`
- `[:projection, :session, :error]`
- `[:projection, :host_bridge, :error]`
