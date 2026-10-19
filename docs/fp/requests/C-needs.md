# Slice C (chat and conversations): requests to other slices

Each item has a local fallback in slice C, so nothing blocks on it.

## F (sim performance; owns `residents.gd`)

1. **Public `Residents.remember(r: Dictionary, line: String)`.** Same behaviour as `_remember`
   (`"Day %d: %s"`, skip an exact repeat, cap 8). C calls it once when a face-to-face
   conversation ends ("talked with a visitor about the power").
   *Fallback in C:* `talk_dialog.gd` `_remember()` appends to `r["memory"]` in the same
   format and caps it at 8 when `has_method("remember")` is false.
2. **Public `Residents.nudge_mood(r: Dictionary, delta: float)`.** Adds `delta` and clamps
   `r["mood"]` to 0..10. C clamps each reply to ±1 and the whole conversation to ±1 before
   calling it.
   *Fallback in C:* the same clamp, written to `r["mood"]` directly.
3. **Optional `heard_in_town` on `card(r)`**: the last two or three chat lines the resident
   read (C can provide them through a callable). Until then, C adds `your_recent_chat` (the
   resident's own last three lines) to the talk prompt itself.

## A (player and interaction)

1. On `bus.conversation_changed(id, true)`: blend to the over-the-shoulder two-shot
   (0.6 s) and turn the hero to face the resident. On `(id, false)`: blend back. C emits
   `(id, true)` in the frame it pushes `&"talk"`, before the card becomes visible, and exactly
   one `(id, false)` on every close path.
2. While `ctx.has_modal(&"talk")`, ignore `interact` (E), so E during a conversation does
   not emit `talk_requested` again. (C ignores a repeated `talk_requested` for the same id, and
   a different id closes the old conversation first.)
3. `chat_feature.is_typing()` is available for the optional reverse shot.
4. The talk card is 600×220 at bottom-centre, 26 px above the screen bottom. It grows upward
   by at most about 40 px for a three-line reply, so the upper 60 % of the screen stays clear.

## E (traffic and pedestrians)

1. On `conversation_changed(id, true)`: stop that resident's agent and face the player. On
   `(id, false)`: release it. `anchor_of(id)` must give A a head to frame.

## B (lean HUD)

1. The place card's "Ask someone here" button emits `bus.card_action("ask_here", tile)`. C
   answers in the talk card, at most once per 20 s, and closes the place card's modal only if
   B asks it to (C pushes `&"talk"` itself).
2. Optional: an unread dot on the minimap from `bus.chat_posted` (`msg.role != "player"`).
   C's own edge tab already shows the unread count.
3. `chat_slot` geometry (0, 80, 460, −268) works as is: the drawer is 440 px, the edge tab
   is 20 px, and the closed ticker sits in the bottom 230 px of the slot, just above the
   minimap.

## I (audio)

1. A soft chat blip on `bus.chat_posted` for system `alert` and `incident` cards and for
   replies to the player (`reply_to` equal to the player's last seq). Every message would be
   too much: the drip releases one every 1.5–3 s.
2. Duck the ambience on `conversation_changed(id, true)` and restore it on `(id, false)`.
