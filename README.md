# Projection

Elixir-authoritative UI for native and embedded apps, rendered by Slint.

> Elixir owns truth. Slint renders a projection of that truth. Rust only bridges the two.

Projection is a UI architecture where all state, routing, validation, and side effects live in Elixir. A Rust + Slint host renders the current view and forwards user intents back. No browser, no HTML, no JavaScript. Communication happens over an OTP port using JSON envelopes and incremental JSON Patch updates.

## Why

Some interfaces don't belong in a browser. Embedded devices, kiosks, appliances: places where you want reliability and live upgrades from Elixir, but need native rendering without a web stack.

Projection gives you a development model inspired by Phoenix LiveView:

- Screens are GenServer-hosted modules with `mount`, `handle_event`, `handle_info`
- State changes produce fine-grained patches, not full re-renders
- Routing is server-side with a nav stack and session boundaries
- The renderer is stateless and can crash and recover via `ready -> render`

But instead of diffing HTML over a WebSocket, you diff a view-model map and send RFC 6902 patch ops over a port.

## How it works

```
Elixir session                         Rust (Slint)
─────────────                          ────────────
Projection.Session                     UI host process
  │                                      │
  │◄──── ready ──────────────────────────┤  (host starts or recovers)
  │                                      │
  ├───── render {rev:1, vm:{...}} ──────►│  (full view-model snapshot)
  │                                      │
  │◄──── intent {name, payload} ────────┤  (user clicked something)
  │                                      │
  ├───── patch {rev:2, ops:[...]} ──────►│  (only what changed)
  │                                      │
```

A clock tick updates one field. A 500-row device list updates one row by ID. The session tracks which assigns changed and only diffs the affected subtree.

## Screen model

A screen is an Elixir module with a typed schema and LiveView-style callbacks. The schema declares what the UI can see. Callbacks decide how state changes in response to events.

```elixir
defmodule MyApp.Screens.Greeter do
  use ProjectionUI, :screen

  schema do
    field :greeting, :string, default: "Hello, world!"
  end

  @impl true
  def handle_event("update_greeting", %{"name" => name}, state) do
    {:noreply, assign(state, :greeting, "Hello, #{name}!")}
  end
end
```

The matching Slint template receives schema fields as properties and sends user actions back as intents:

```slint
export component GreeterScreen inherits VerticalLayout {
    in property <string> greeting: "Hello, world!";
    callback ui_intent(intent_name: string, intent_arg: string);

    Text {
        text: root.greeting;
        font-size: 24px;
        horizontal-alignment: center;
    }
}
```

Elixir updates `greeting`, the session diffs the view-model, and one `replace /greeting` patch op arrives in Slint. That's the whole loop.

Scalar schema fields (`:string`, `:bool`, `:integer`, `:float`) are codegen-bound directly to Slint properties. Container fields (`:map`, `:list`) are read through VM lookup callbacks at runtime.

## Routing

Routes are defined with a DSL inspired by Phoenix's router. `screen_session` blocks act as navigation boundaries, and cross-session navigation is blocked like LiveView's `live_session`.

```elixir
defmodule MyApp.Router do
  use Projection.Router.DSL

  screen_session :main do
    screen "/clock", MyApp.Screens.Clock, :show, as: :clock
    screen "/devices", MyApp.Screens.Devices, :index, as: :devices
  end
end
```

The UI sends `ui.route.navigate`, `ui.route.patch`, or `ui.back` intents. Elixir validates the transition and patches the view-model with the new screen state.

## Getting started

Requires Elixir, Rust, and Cargo.

```bash
mix deps.get
mix compile          # runs codegen + builds Rust host
mix ui.preview       # launches the demo
```

```bash
mix test             # run Elixir test suite
mix projection.codegen   # regenerate Rust bindings from schemas
```

## Project layout

```
lib/projection/          session, protocol, router, patch
lib/projection_ui/       screen behaviour, schema DSL, state, port supervision
lib/projection_ui/screens/
  clock.ex               screen controller (Elixir)
  templates/clock.slint  screen template (Slint)
  layouts/app_shell.slint
slint/ui_host/           Rust host, protocol bridge, generated bindings
```

Elixir screen controllers and their Slint templates live side by side. The codegen pipeline reads `__projection_schema__/0` from each screen module at compile time and generates typed Rust setters under `slint/ui_host/src/generated/`.
