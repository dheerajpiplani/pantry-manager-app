# Pantry bot

A WhatsApp and Telegram bot that tracks what's in your kitchen and suggests
what to cook. Built as n8n workflows over a Supabase (Postgres) database,
with Google Gemini for language understanding.

## How it works

Every message, from either channel, flows through one router workflow:

```
Telegram Trigger ─┐
                  ├→ Normalize Message   one shape for both channels
WhatsApp Webhook ─┘
                   ↓
            Resolve household            user_id → household_id
                   ↓
              Get Session                any question pending?
                   ↓
             Build Context               text, user, household, session
                   ↓
             Dedupe check                ignores retried webhooks
                   ↓
            Session router ──────────────→ Household flow   (mid-onboarding)
                   │                     → Leave flow       (mid-confirmation)
                   ↓
              AI Agent                   classify intent
                   ↓
               Switch ──────────────────→ Pantry-update
                                         → show-pantry
                                         → Invite code flow
                                         → Leave flow
                                         → fallback help text
                   ↓
          IF channel → Telegram / WhatsApp send
```

Each sub-workflow returns `{ user_id, channel, reply }`. The router sends it.

### Two routing layers

**Session state wins over intent.** If someone is halfway through a
conversation — answering "new or join?", or confirming a household exit —
their next message is an *answer*, not a new request. The Session router
checks `session_step` before anything reaches the classifier.

**Intent classification handles everything else.** A Gemini call with a
constrained output schema returns one of a fixed set of intents, plus mood
and any query filters. No keyword matching, so "can you list everything in
my pantry?" works as well as "show pantry".

## Workflows

| Workflow | Does |
|---|---|
| Main (router) | Triggers, normalization, household lookup, dedupe, routing, sending |
| Pantry-update | Parses "add 2 kg rice and 6 eggs" into rows and writes them |
| show-pantry | Reads the pantry, with optional item and stock filters |
| Household flow | Onboarding: new household, or join one with a code |
| Invite code flow | Returns the household's invite code |
| Leave flow | Leaves a household, with confirmation if you're the last member |

## Data model

Five tables, in `schema.sql`:

- **households** — one per kitchen, carries the invite code
- **household_members** — maps a Telegram chat id or WhatsApp number to a household
- **pantry** — items, keyed by `(household_id, item)`
- **sessions** — one row per user, holds the pending question
- **processed_messages** — message ids already handled, so retries are ignored

Business rules live in Postgres functions rather than in the workflows, so
they can't be bypassed and would survive a rewrite of the orchestration layer.

### Units

Everything is stored in base units: **g**, **ml**, **piece**. The parser
converts on the way in (kg, lb, oz → g; l → ml) and replies convert back out
to imperial for display.

An item's unit is fixed at first use. "3 lb tomatoes" stores grams; a later
"2 tomatoes" is rejected rather than guessed at, because converting between
count and weight would silently corrupt the quantity. To switch, delete the
item and add it again.

## Setup

1. Create a Supabase project and run `schema.sql`.
2. Import the workflow JSON files into n8n.
3. Create three credentials: Supabase (service key), Telegram (BotFather
   token), Google Gemini (AI Studio key).
4. Point the Telegram and WhatsApp webhooks at the running instance.

n8n runs in Docker with `WEBHOOK_URL` set to the public address — a tunnel
while developing locally, a real domain once deployed.

## Still to build

- **What to eat** — preference chat, recipe generation from pantry contents,
  recipe video links
- **Deduct after cooking** — subtract a cooked recipe's ingredients
- **Expiry tracking** — shelf life per item, "what's going off", recipes that
  prioritise it
- **Categories** — group the pantry listing instead of one flat list
- **Photo input** — receipts, groceries on a counter, barcodes
