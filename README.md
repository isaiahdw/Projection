# Projection

Elixir-authoritative UI for native and embedded apps, rendered by Slint.

> Elixir owns truth. Slint renders a projection of that truth. Rust only bridges the two.

> Note: This project is mostly AI-generated and is not yet designed, hardened, or tested for production systems.

Projection is a UI architecture where all state, routing, validation, and side effects live in Elixir. A Slint host renders the current view and forwards user intents back. No browser, no HTML, no JavaScript. Communication happens over an OTP port using JSON envelopes and incremental JSON Patch updates.

You work in two languages: **Elixir** for all logic and state, and **Slint** for layout and visuals. Rust exists in the project as internal infrastructure -- a static bridge binary that reads patches from stdin and writes intents to stdout. You don't write Rust, modify Rust, or need to know Rust. The bridge code is either static plumbing or auto-generated from your Elixir schemas at compile time.

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

### The loop in detail

There are two event loops that never block each other.

**Elixir side.** A `Projection.Session` GenServer holds all authoritative state for one UI instance. It hosts a screen module (like `Clock` or `Devices`), manages a nav stack, and keeps a monotonic revision counter. When state changes -- from an intent, a timer tick, or a domain event -- the session re-renders the screen's assigns into a view-model map, diffs it against the previous snapshot, and emits JSON Patch ops. Only the changed subtree is diffed: if `clock_text` is the only assign that changed, only `/clock_text` is compared, even if there's a 500-row device list in the same VM.

**The host binary.** The Rust side is infrastructure you don't touch. It's a small binary that runs Slint's event loop on the main thread: a reader thread pulls length-prefixed JSON frames from stdin (the OTP port), and a writer thread pushes intent envelopes to stdout. All Slint mutations happen on the UI thread via `upgrade_in_event_loop`. The host keeps a shadow copy of the full VM JSON so it can apply incremental patches without needing the full tree each time. The code is either static plumbing (protocol framing, thread wiring, patch application) or auto-generated from your Elixir schemas by `mix projection.codegen`. You never edit it directly.

**The bridge.** `ProjectionUI.PortOwner` is a GenServer that owns the OS port process. It decodes inbound envelopes and casts them to the Session, and encodes outbound envelopes to the port. If the port crashes, it reconnects with bounded exponential backoff. On reconnect, the host sends `ready` and the session replies with a full `render` -- the host doesn't need to persist anything.

Both processes live under a `SessionSupervisor` with `:rest_for_one` strategy: if the Session crashes, the PortOwner restarts too. If the PortOwner crashes, the Session keeps its state and just re-renders when the new host connects.

### Protocol

Communication uses JSON envelopes over `{:packet, 4}` framed stdio:

- **`ready`** -- UI host announces it's alive. Session replies with a full render.
- **`render`** -- Full VM snapshot with a revision number.
- **`intent`** -- User action from the UI (e.g. `clock.pause`, `ui.route.navigate`). Includes a monotonic ID for ack tracking.
- **`patch`** -- Incremental update. Contains RFC 6902 ops (`replace`, `add`, `remove`) and the new revision. Can optionally ack the intent that caused it.
- **`error`** -- Recoverable protocol error.

The host validates that each revision is exactly `last_rev + 1`. If a revision is stale, skipped, or arrives before the initial render, the host resets its state and sends `ready` to resync.

### Bindings and codegen

Each screen declares a typed schema in Elixir:

```elixir
schema do
  field :clock_text, :string, default: "--:--:--"
  field :clock_running, :bool, default: true
end
```

At compile time, `mix projection.codegen` reads `__projection_schema__/0` from every screen module and generates a Rust module per screen under `slint/ui_host/src/generated/`. Each generated module has:

- `apply_render` -- sets all typed Slint properties from a full VM JSON blob
- `apply_patch` -- dispatches patch ops to the correct typed setter by path
- Per-field helpers like `set_clock_text_from_value` that parse JSON into the right Slint type

This means the Rust host never contains domain logic or hand-written property bindings. It stays policy-free: the shape of each screen is defined in Elixir and flows through codegen.

The generated Slint layer includes a `screen_host.slint` and root `app.slint`, so adding a new screen route no longer requires manually editing root Slint imports or screen switch branches.

### Ephemeral UI state

Projection draws a clear line between authoritative state and ephemeral UI state:

- **Elixir owns:** field values, validation results, routing, permissions, domain data
- **Slint owns:** text drafts while typing, focus, cursor position, scroll offsets, animations

The UI commits to Elixir on discrete actions: blur, enter, button clicks, toggles, selections. Elixir validates on commit and patches back accepted or corrected values. This avoids per-keystroke round-trips over the port.

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
import { UI } from "ui.slint";

export component GreeterScreen inherits VerticalLayout {
    in property <string> greeting: "Hello, world!";

    Text {
        text: root.greeting;
        font-size: 24px;
        horizontal-alignment: center;
    }

    // Example user action
    TouchArea {
        clicked => {
            UI.intent("update_greeting", "alice");
        }
    }
}
```

Elixir updates `greeting`, the session diffs the view-model, and one `replace /greeting` patch op arrives in Slint. That's the whole loop.

Schema fields are codegen-bound directly to Slint properties. Current built-in bindings support `:string`, `:bool`, `:integer`, `:float`, `:list` (list of strings), and `:id_table` for stable-ID row data.

Performance note:
- `:list` works well for small or mostly-static collections.
- For large or high-churn collections, prefer `id_table` so updates can target rows by stable ID instead of replacing whole lists.

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
lib/projection_ui/       screen behaviour, schema DSL, state, runtime supervision
  runtime/               port owner and session supervisor
lib/projection_ui/screens/
  clock.ex               screen controller (Elixir)
lib/projection_ui/ui/    Slint UI files (app shell + screen templates)
  clock.slint
  app_shell.slint
slint/ui_host/           Rust host, protocol bridge, generated bindings
  src/generated/         generated app root + screen host + Rust setters
```

Elixir screen controllers live in `lib/projection_ui/screens`, and Slint files live in `lib/projection_ui/ui`. The codegen pipeline reads `__projection_schema__/0` from each screen module at compile time and generates typed Rust setters under `slint/ui_host/src/generated/`.
