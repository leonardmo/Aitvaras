# Future directions

The guiding thesis (user, 2026-07-07): *the more Aitvaras knows about the
day and the more signals she gets, the more useful she is.* Everything is
local, so richer context is a feature, not a privacy cost. The bar: each
signal must change a **decision** Aitvaras makes rather than only being displayed.

## Tier 1: high impact, clearly useful

### Context/presence engine (the backbone)
A single `Context` the agent always sees: time, day-of-week, calendar
state (in a meeting? free?), focus-session state, location label, network
(home/uni/eduroam SSID), battery/power, recent activity. Most features
below are just *consumers* of this context. Build this first; it's the
multiplier.

- **Location by meaning, not coordinates.** The useful signal is "at university" vs "home" vs "out", not
  raw coordinates. Cheapest reliable
  source on macOS: **Wi-Fi SSID** (no permission prompt, instant) mapped
  to named places the user defines once ("eduroam → University"). Add
  CoreLocation later only if SSID is insufficient. This directly changes
  triage: a TUM mail while *at* university is more actionable than the
  same mail at home on a Sunday; "when do I have to leave" only makes
  sense with a place.
- **Calendar-aware everything.** Aitvaras already reads the calendar; she
  should *use* it passively: suppress nudges during a meeting, pre-brief
  before the next event ("seminar in 10 min, room X, here's the last
  email about it"), protect focus time that's already blocked.

### Proactive daily rhythm
- **Morning brief** (once, on first unlock): today's calendar, open
  goals, overnight mail worth knowing, deadlines within N days. One
  spoken paragraph. This is the single most "assistant-like" feature and
  reuses the briefing composer already built for breaks.
- **End-of-day wrap** (optional): goals hit, what slipped → tomorrow.

### Memory that compounds
Aitvaras has a memory store but barely writes to it. Let the background model
*propose* durable facts from conversations and mail ("your exam is July
24", "you prefer 50-min focus blocks", "Anna = study partner"), user
approves. Feeds every future decision. Highest long-term payoff.

## Tier 2: useful once Tier 1 exists

- **Commute / "leave now".** Calendar event with a location + travel time
  → a heads-up to leave. Needs a maps/travel-time source; the *decision*
  (when to leave) is genuinely useful, unlike raw weather.
- **Weather, but only decision-shaped.** Raw forecast is a gimmick. Two
  real uses: (a) rain before a commute/known outdoor calendar event →
  "take a jacket, rain at 5 when you head out"; (b) nothing else. Gate it
  behind calendar+location so it only speaks when it changes an action.
- **Deadline radar.** Moodle + mail + calendar fused into one ranked
  "what's due and how close" view, surfaced proactively as things
  approach rather than only when asked.

## Tier 3: bigger builds / higher risk

- **Messenger bridge (WhatsApp/Signal via whatsmeow).** The one real gap
  in "lunch invite from a friend": notification-reading covers banners,
  but true message access + replies needs a bridge. ToS-grey, separate
  project.
- **Screen/document awareness.** "What am I looking at" via periodic OCR
  or the accessibility tree → Aitvaras can help with the actual thing on
  screen. Powerful, heavier, needs careful scoping.
- **On-device learning of work patterns.** Which apps/sites are "work"
  for *this* user, typical focus length, when energy dips → personalized
  nudge timing. Start as simple stats, not ML.

## Explicitly *not* worth it (avoid gimmicks)
- Standalone weather widget, generic "read me the news", chit-chat
  personas, decorative dashboards. If it doesn't change a decision or
  save a real action, it's noise.

## Ordering
1. Context/presence engine (SSID location + calendar state): unlocks the rest.
2. Morning brief + memory proposals: immediate daily value.
3. Leave-now / decision-shaped weather: once context exists.
4. Deadline radar, messenger bridge, screen awareness: later.
