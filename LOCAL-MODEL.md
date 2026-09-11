# Running the namer on a local model

`literate-workspace-namer` has always had a `local` backend that speaks
OpenAI-compatible `/v1/chat/completions`. This document is the other half:
what to point it at, and whether that is a good idea.

**Verdict up front: marginal, and not today's default.** A 3B model on this
machine names *one changed workspace* about as well as Claude Haiku, and only
fractionally slower than it -- 1.17 s against 0.86 s, behind a 3-second
debounce. It falls apart on the wide prompts — naming ten workspaces at once,
and `--triage`. The numbers are below; make your own call.

## What is installed

Everything is rootless. Nothing here needs `sudo`, and nothing was installed
through `pacman`.

| Piece | Where |
|---|---|
| llama.cpp source | `~/.local/src/llama.cpp` |
| binaries (`llama-server`, `llama-cli`, …) | `~/.local/bin` |
| shared libs | `~/.local/lib` |
| CMake 3.31.6 (Arch ships none here) | `~/.local/src/cmake-3.31.6-linux-aarch64` |
| model | `~/.local/share/literate-models/Qwen2.5-3B-Instruct-Q4_K_M.gguf` |
| service | `~/.config/systemd/user/llama-server.service` |

## Building llama.cpp

`cmake` is not installed and cannot be, so an official aarch64 tarball is
unpacked under `~/.local/src` and used from there.

```sh
mkdir -p ~/.local/src && cd ~/.local/src
curl -LO https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-linux-aarch64.tar.gz
tar xzf cmake-3.31.6-linux-aarch64.tar.gz
export PATH=~/.local/src/cmake-3.31.6-linux-aarch64/bin:$PATH

git clone --depth 1 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build-cpu \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$HOME/.local \
  -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib' \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DGGML_NATIVE=ON \
  -DLLAMA_CURL=ON \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DBUILD_SHARED_LIBS=ON
cmake --build build-cpu -j8 && cmake --install build-cpu
```

`GGML_NATIVE=ON` detects the M1 Pro correctly and compiles with
`-mcpu=apple-m1+crc+aes+sha3+fp16+dotprod`. It probes for and *does not* find
SVE, SME or i8mm — an M1 has none of them — so this is plain NEON with dotprod
and fp16 arithmetic. That is the expected result on this hardware.

**The RPATH flags are not optional.** Without them `cmake --install` strips
the build-tree RPATH, `~/.local/lib` is not on the loader's search path, and
every installed binary dies with `libllama-server-impl.so: cannot open shared
object file`.

### No GPU

CPU only. The Asahi GPU is a real Vulkan device — probing `libvulkan` reports
`Apple M1 Pro (G13S C0)`, Vulkan 1.4.354, with `shaderInt16`,
`VK_KHR_16bit_storage`, `VK_KHR_shader_float16_int8` and
`VK_EXT_subgroup_size_control` (no `VK_KHR_cooperative_matrix`, which
llama.cpp does not require) — so a Vulkan backend is not obviously
impossible. It was not built, for a reason that is decisive here: the Vulkan
**headers** are not installed and `vulkan-headers` cannot be added without
root. They can be unpacked from a tarball into `~/.local/src` like CMake was,
so this is worth revisiting; it is a "not attempted", not a "does not work".
Given that a 3B Q4 model already runs at 37 tok/s on the CPU cores and the
bottleneck in daily use is prompt processing, the upside is likely small.

## The model

`Qwen2.5-3B-Instruct-Q4_K_M.gguf`, 1.93 GB, from
`bartowski/Qwen2.5-3B-Instruct-GGUF`. Q4_K_M rather than a Q4_0 variant
because the repacked `Q4_0_4_8` kernels want i8mm, which this CPU does not
have, so there is nothing to gain from the plainer quant.

Qwen2.5-3B was picked over Llama-3.2-3B for its stronger structured-output
behaviour, and on format it holds up. Across roughly forty calls it never
emitted malformed JSON, never refused to answer, never replied in a language
other than English, and never named an icon outside Phosphor's 1530 — the
daemon's `clean()` never had to substitute `app-window` once.

The one format rule it does break is length. Asked for "1-3 words, at most 18
characters" it occasionally overruns, and `clean()`'s hard clamp then cuts a
word in half: one run produced `Omarchy & Claudeto`, which is a truncated
`Omarchy & Claude Code`-ish name rather than anything a person would write.
Haiku was never observed to overrun. Everything else the model gets wrong is
about *reading the input*, not about format — which is why constrained
decoding does not help it (below).

## The service

`~/.config/systemd/user/llama-server.service` (tracked in the `~/.config`
repo) runs the server on `127.0.0.1:8077`, enabled on login:

```sh
systemctl --user daemon-reload
systemctl --user enable --now llama-server.service
curl -s http://127.0.0.1:8077/health          # {"status":"ok"}
```

It runs `Nice=10` with `CPUWeight=50`: six threads of inference will otherwise
make the desktop stutter, and a workspace name is never urgent. The model is
mmapped, so a restart costs about a second, but the unit keeps the process
alive anyway — the namer is bursty and would pay that load on every call.

`--cache-reuse 256` matters more than it looks. The ~1050-token system prompt
is identical on every call, and the server's slot cache reuses it verbatim
(`f_sim_best = 1.000`), so only the handful of tokens describing the actual
windows get processed. Without it every call would re-evaluate the whole
prompt at ~110 tok/s, adding about ten seconds.

## Switching the namer over

Nothing switches automatically. `~/.config/literate/config.json` still points
at the API. To try local, add three keys:

```json
{
  "api_key_file": "~/api-keys/literate-claude-api-key",
  "backend": "local",
  "local_url": "http://127.0.0.1:8077/v1/chat/completions",
  "local_model": "qwen2.5-3b-instruct"
}
```

Set `"backend"` back to `"auto"` to return to Haiku. `local_model` must match
the server's `--alias`; the endpoint ignores the field, but the daemon logs it.

To evaluate without touching the live config, point `HOME` at a throwaway
directory holding only `.config/literate/config.json` — the daemon resolves
every path from `HOME`, and `--test` writes nothing:

```sh
HOME=/tmp/evalhome ./bin/literate-workspace-namer --test fixtures/eval.json
```

## Measured latency

Median wall-clock for one `ask()`, prompts all distinct so the server's slot
cache reuses the system prefix but never a whole reply. Local numbers are
`n=10` for the single-workspace case and `n=5` for the batch.

| Call | Haiku 4.5 (API) | Qwen2.5-3B (local) |
|---|---|---|
| name 1 workspace | 0.86 s | **1.17 s** |
| name 10 workspaces | 2.23 s | **5.94 s** |
| `--suggest`, 7 windows | 1.5 s | 5.2 s |
| `--triage`, 19 windows | 3.0 s | 5.5 s |

Generation runs at ~37 tok/s, prompt processing at ~110 tok/s, on six
threads. Single-workspace replies are short enough that the gap to Haiku is
round-trip noise; the batch gap is generation-bound and scales with the
number of workspaces. A call that misses the slot cache pays the full ~1050
token prompt at 110 tok/s -- the 3.4 s and 8.5 s outliers in the samples
above are those.

The single-workspace figure is the one that matters. `run_pass()` only asks
about workspaces whose window signature actually changed, which is almost
always one, and the daemon already sits behind a 3-second debounce.

## Quality

Naming the ten-workspace `fixtures/eval.json` in one call. Haiku is stable
across runs; local is not, so its column shows what varied.

| WS | Windows | Haiku 4.5 | Qwen2.5-3B, all 10 at once |
|---|---|---|---|
| 1 | Gmail | Email | Email |
| 2 | Gmail inbox + invoice thread | Email | **Lisbon Trip** / Email |
| 3 | Claude Code, "Shift-Super-A window behavior" | Window Behavior | Shift-super-a / Coding / Behavior |
| 4 | Claude Code, omarchy window management | Omarchy / Omarchy Ui | **Auth Token Rfc** / Auth Rfc / Omarchy |
| 5 | four unrelated Chrome tabs | Browsing / Research | **Auth Token Rfc** / **Email** / Auth Refactor |
| 6 | Google Flights + Booking.com | Lisbon Trip | Lisbon Trip / Trip / Flight to Lisbon |
| 7 | Slack #eng-platform + auth RFC doc | Auth Token Rfc | Auth Token Rfc / Auth |
| 8 | nvim Bar.qml + shell in ~/src/omarchy | Omarchy | Omarchy / Coding |
| 9 | Spotify | Music | Music / Spotify |
| 10 | `yay -S ttf-phosphor-icons` + Downloads | Setup / Fonts | Yay Downloads / Nautilus / Terminal / Yay |

The bolded answers are not near-misses, they are answers to a different
question — and they turn out to have a single cause, which is the most useful
thing in this document.

### The few-shot examples leak, and it is the repo's prompt's fault

`system_prompt()` ends with five worked examples numbered `Workspace 1` …
`Workspace 5`, answered by a JSON block keyed `"id": "1"` … `"id": "5"`. Real
workspace ids are also 1..5. Asked to name one workspace, the 3B model
sometimes replies with the example answer, verbatim:

```
{"workspaces": [
  {"id": "1", "name": "email", "icon": "envelope"},
  {"id": "2", "name": "lisbon trip", "icon": "airplane"},
  {"id": "3", "name": "billing", "icon": "receipt"},
  {"id": "4", "name": "auth token rfc", "icon": "key"},
  {"id": "5", "name": "email", "icon": "envelope"}
]}
```

That is the example block copied out of the system prompt. It explains every
bolded cell above: workspace 2 becomes "Lisbon Trip" and workspace 4 becomes
"Auth Token Rfc" because those are what examples 2 and 4 say. It also explains
the occasional `??` in `--test` output — the reply is about the examples, so
the id the daemon actually asked for is sometimes missing entirely.

Two experiments confirm it:

- Renumbering the fixture's workspaces to 6..10 (same windows, ids that cannot
  collide) makes the model answer correctly — including the workspaces it had
  got wrong at ids 1..5.
- Renumbering the *examples* to `Workspace A` … `Workspace E`, changing
  nothing else, fixes it in place.

With lettered example ids, all ten workspaces in one call:

| WS | Haiku 4.5 | Qwen2.5-3B, examples A–E |
|---|---|---|
| 1 | Email | Email |
| 2 | Email | Email |
| 3 | Window Behavior | Behavior |
| 4 | Omarchy Ui | Omarchy |
| 5 | Research / Browsing | One-three |
| 6 | Lisbon Trip | Trip |
| 7 | Auth Token Rfc | Auth Rfc |
| 8 | Omarchy | Omarchy |
| 9 | Music | Music |
| 10 | Setup | Downloads |

Eight of ten are now reasonable, the wrong ones are merely thin rather than
unrelated, and — importantly for a bar widget — three consecutive runs were
*identical*, where the contaminated prompt produced a different answer every
time.

**This change has not been made to `bin/literate-workspace-namer`.** It was
tested by wrapping `system_prompt()` from outside the repo. Haiku scores the
same with lettered example ids as with numbered ones, so the change looks free
and worth making, but it belongs in its own reviewed commit.

### `--suggest` is fine

The one path where the local model is genuinely competitive. Given a workspace
holding an auth refactor plus three patio-furniture tabs:

| | Haiku 4.5 | Qwen2.5-3B |
|---|---|---|
| name | Auth Token / code | Auth Refactor / code |
| spin-out group | Patio Furniture / armchair, windows 4–6 | Outdoor Furniture / chair, windows 4–6 |

Correct indices, valid icons, sensible name. `--suggest` asks about one
workspace and its examples carry no ids, which is exactly the shape the model
handles well.

### `--triage` is not usable

19 windows, one call, group by activity:

| Haiku 4.5 | Qwen2.5-3B |
|---|---|
| Email → the 3 Gmail windows | Email → the 3 Gmail windows **+ Booking.com** |
| Lisbon Trip → Flights, Booking.com | Lisbon Trip → Flights, **Slack #eng-platform**, **auth RFC doc**, **Spotify** |
| Work Discussion → Slack, auth RFC | Development → the 3 agent terminals, 4 unrelated Chrome tabs, **Nautilus**, **yay** |
| Omarchy Project → agent terminals, nvim, shell | Uncategorised → nvim Bar.qml, shell in ~/src/omarchy |
| Website Monitoring, Music, System Setup, Files | |

The JSON is well-formed and every index lands in exactly one group, so the
daemon's validation passes it through happily — the output is simply wrong.
It also invents an "Uncategorised" bucket that the prompt explicitly tells it
not to create, and files the two most obviously-related windows on the whole
desktop into it. The pattern across all three paths is consistent: this model
degrades with the *width* of the question, not its difficulty.

### Constrained decoding does not help

llama.cpp can force output to a JSON schema, and the daemon already has
`OUTPUT_SCHEMA` to hand it. Four variants of the same ten-workspace call, via
`response_format: {"type": "json_schema", ...}`:

| Variant | Time | JSON | Missing ids | Verdict |
|---|---|---|---|---|
| no schema, example ids 1–5 | 6.2 s | valid | none | contaminated (ws 2 "Lisbon Trip") |
| `OUTPUT_SCHEMA` as shipped | 6.3 s | valid | none | contaminated, names unchanged |
| tightened schema, ids 1–5 | 6.8 s | valid | none | contaminated *more* (ws 4 "Auth Token Rfc", ws 5 "Email") |
| tightened schema, example ids A–E | 11.5 s | valid | none | good — matches the unconstrained A–E result |

"Tightened" means ids pinned to an `enum` of exactly the workspaces asked
about, `minItems`/`maxItems` fixed to that count, `name` capped at
`max_name_chars`, and `icon` constrained to the 1530 real Phosphor names.

The conclusion is unambiguous: **schema constraints cost a little latency and
buy no quality.** Every variant already produced valid JSON with every
requested id present — including the unconstrained one — because malformed
JSON was never the failure. Constraining ids 1–5 while the examples still use
ids 1–5 made the *names* slightly worse, not better; the only variant that
looks good is the one that fixes the example ids, and it looks exactly as good
without a schema.

What the tightened schema does buy is a guarantee rather than an improvement:
a reply that drops or invents a workspace id becomes unrepresentable, so the
`??` that example contamination can produce cannot occur by construction. That
failure did not fire in this particular test, so this is a belt-and-braces
argument, not a measured win. The `maxLength` on `name` would likewise stop
the mid-word truncation noted earlier — at the cost of the model being cut off
mid-token instead, which is not obviously better.

## Honest verdict

**Marginal. Usable for the daemon's normal job, not for the wide prompts.**

- Day-to-day naming, one changed workspace at a time, hidden behind a
  3-second debounce: yes. Roughly Haiku quality, 0.3 s slower, free,
  and the window titles never leave the machine — which for a feature that
  reads every window title and Chrome URL is not a small thing.
- `--suggest`: yes.
- `--triage`: no. Wrong enough to be worse than nothing.
- Batch naming after a restart, when every workspace is pending at once:
  degraded, and today actively broken by the example-id collision.

If this is to become the default, in order of value for effort:

1. **Renumber the few-shot example ids** in `system_prompt()` so they cannot
   collide with real workspace ids. Cheap, no downside for Haiku, and the
   single biggest quality win measured here.
2. **Cap the batch size on the local backend** — ask about a handful of
   workspaces per call rather than all of them. Width is this model's real
   failure mode.
3. **A bigger model for `--triage`**, or leave `--triage` on the API. A 7B at
   Q4 would roughly double latency, which `--triage` can afford (it is an
   explicit user action) and the daemon cannot.

Constrained decoding is not on that list. It is a correctness belt-and-braces
measure, not a quality fix.
