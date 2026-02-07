# Projection

Projection is a UI architecture where application state, behavior, and routing live in Elixir processes, and a Rust + Slint renderer displays a projection of that state via incremental updates (patches). No browser. No server-driven layout. Minimal, policy-free adapter.

Status: planning, doc-first.

**Docs**
- `docs/CONTEXT.md` full architecture and protocol spec
- `TASKS.md` milestones and execution plan
- `docs/milestones/` milestone-specific deliverables and acceptance criteria
- `docs/RESEARCH_NOTES.md` Slint and Elixir port reference notes
- `docs/PREFLIGHT.md` go/no-go checklist before scaffolding

**Locked Decisions**
- Name: Projection (standalone, no LiveView naming)
- Repo: single git repo, Mix umbrella
- Apps: `apps/projection` (Elixir library) and `apps/projection_demo` (example app)
- Renderer implementation dir: `slint/`
- UI host language: Rust
- Renderer: Slint
- Transport: OTP Port (stdin/stdout, framed)
- Protocol: JSON envelopes + JSON Patch (RFC6902 subset)
- Target: RK3566-class embedded device (platform-agnostic architecture)

**Non-Goals**
- No browser, HTML, CSS, JS
- No server-driven layouts or widget trees
- No imperative UI commands from Elixir (open modal, scroll, animate)
- No domain logic in Rust UI host
- No per-keystroke round-trips (use commit semantics)

**Hard Constraints**
- Firmware size, predictable performance, reliability are top priorities
- UI contributors edit only `.slint` files + assets
- Partial updates must be fine-grained (clock tick updates only one label)
- Lists update single rows by stable ID
- UI must recover cleanly on restart via `ready -> render`

**Dual Event Loop Model**
- Elixir/BEAM loop is authoritative (state, routing, validation, workflows, side effects)
- Slint UI loop is renderer-only (input, redraw, animations, windowing)
- Rust bridge connects them with background reader and writer threads plus a non-blocking UI thread
- All Slint mutations happen on the Slint UI thread via `slint::invoke_from_event_loop(...)` or `Weak::upgrade_in_event_loop(...)`

**Protocol Invariants**
- Frames are length-prefixed JSON on stdin/stdout
- Frame caps: `1_048_576` bytes (Elixir -> UI) and `65_536` bytes (UI -> Elixir)
- Each message includes `sid` and monotonic `rev` (`render` and `patch`)
- Intents include monotonic client `id`; server may echo with `ack`
- Unknown or out-of-order revisions are rejected and force `ready -> render` resync
- Patch scope is RFC6902 subset (`add`, `remove`, `replace`) with RFC6901 path escaping
- UI callbacks never block on port IO; intents are queued to an outbound writer thread

**Runtime and Deployment Notes**
- For Elixir ports, prefer `Port.open(..., [:binary, {:packet, 4}, :exit_status, :use_stdio])`
- Supervision policy: per-session `SessionSupervisor` with `:rest_for_one`; `PortOwner` reconnects with bounded exponential backoff
- Development runtime: macOS uses `SLINT_BACKEND=winit`
- Target runtime: RK3566 Linux uses `SLINT_BACKEND=linuxkms`
- Slint backend selection order is `qt`, then `winit`, then `linuxkms`
- `linuxkms` is not built in by default; enable and validate it explicitly for compositor-free embedded targets
- `SLINT_BACKEND` can force backend/renderer selection during bring-up and profiling

**Canonical Rule**
Elixir owns truth. Slint renders a projection of that truth. The Rust host only bridges the two.
