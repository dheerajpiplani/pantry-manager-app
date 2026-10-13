-- Pantry bot — Supabase / Postgres schema
-- Run top to bottom on a fresh project.

-- ─────────────────────────────────────────────────────────────
-- Tables
-- ─────────────────────────────────────────────────────────────

create table households (
  id bigint generated always as identity primary key,
  name text,
  invite_code text unique default upper(substring(md5(random()::text), 1, 6)),
  created_at timestamptz default now()
);

create table household_members (
  user_id text primary key,
  household_id bigint references households(id) on delete cascade,
  channel text,
  joined_at timestamptz default now()
);

create table pantry (
  id bigint generated always as identity primary key,
  household_id bigint references households(id) on delete cascade,
  item text not null,
  quantity numeric not null default 0,
  unit text,
  updated_at timestamptz default now(),
  unique (household_id, item)
);

create table sessions (
  user_id text primary key,
  step text,
  answers jsonb default '{}',
  suggestions jsonb,
  updated_at timestamptz default now()
);

create table processed_messages (
  channel text not null,
  message_id text not null,
  user_id text,
  created_at timestamptz default now(),
  primary key (channel, message_id)
);


-- ─────────────────────────────────────────────────────────────
-- Household functions
-- ─────────────────────────────────────────────────────────────

-- Lookup only. Returns the household id, or no row if the user has none.
create or replace function find_household(p_user_id text)
returns bigint as $$
  select household_id from household_members where user_id = p_user_id;
$$ language sql;


-- Creates a fresh household and makes this user its first member.
create or replace function create_household(p_user_id text, p_channel text)
returns bigint as $$
declare h_id bigint;
begin
  insert into households (name) values ('Household') returning id into h_id;
  insert into household_members (user_id, household_id, channel)
  values (p_user_id, h_id, p_channel)
  on conflict (user_id) do update set household_id = h_id;
  return h_id;
end;
$$ language plpgsql;


-- Attaches the user to an existing household by invite code.
-- Returns null if the code does not match.
create or replace function join_household(p_user_id text, p_code text, p_channel text)
returns bigint as $$
declare h_id bigint;
begin
  select id into h_id from households
  where invite_code = upper(replace(replace(trim(p_code), ' ', ''), '-', ''));
  if h_id is null then return null; end if;
  insert into household_members (user_id, household_id, channel)
  values (p_user_id, h_id, p_channel)
  on conflict (user_id) do update set household_id = h_id;
  return h_id;
end;
$$ language plpgsql;


-- Removes the user's membership entirely, so their next message
-- routes back to onboarding. Deletes the household (and its pantry,
-- via cascade) if they were the last member.
create or replace function leave_household(p_user_id text, p_channel text)
returns table(left_household bigint) as $$
declare old_id bigint; remaining int;
begin
  select household_id into old_id from household_members where user_id = p_user_id;
  delete from household_members where user_id = p_user_id;
  select count(*) into remaining from household_members where household_id = old_id;
  if remaining = 0 then
    delete from households where id = old_id;
  end if;
  return query select old_id;
end;
$$ language plpgsql;


-- Members and non-empty items in the user's household.
-- Used to decide whether leaving needs a confirmation.
create or replace function household_member_count(p_user_id text)
returns table(member_count int, item_count int) as $$
  select
    (select count(*)::int from household_members hm2
      where hm2.household_id = hm.household_id),
    (select count(*)::int from pantry p
      where p.household_id = hm.household_id and p.quantity > 0)
  from household_members hm
  where hm.user_id = p_user_id;
$$ language sql;


-- The household's invite code, for sharing.
create or replace function get_invite_code(p_user_id text)
returns table(invite_code text) as $$
  select h.invite_code from households h
  join household_members hm on hm.household_id = h.id
  where hm.user_id = p_user_id;
$$ language sql;


-- ─────────────────────────────────────────────────────────────
-- Session functions
-- ─────────────────────────────────────────────────────────────

-- Always returns exactly one row, so n8n nodes downstream always run.
-- Sessions older than an hour are treated as expired.
create or replace function get_session(p_user_id text)
returns table(step text, answers jsonb) as $$
  select
    coalesce(s.step, '') as step,
    coalesce(s.answers, '{}'::jsonb) as answers
  from (select 1) dummy
  left join sessions s
    on s.user_id = p_user_id
   and s.updated_at > now() - interval '1 hour';
$$ language sql;


create or replace function set_session(p_user_id text, p_step text, p_answers jsonb)
returns void as $$
  insert into sessions (user_id, step, answers, updated_at)
  values (p_user_id, p_step, coalesce(p_answers, '{}'::jsonb), now())
  on conflict (user_id) do update set
    step = p_step, answers = coalesce(p_answers, '{}'::jsonb), updated_at = now();
$$ language sql;


create or replace function clear_session(p_user_id text)
returns void as $$
  delete from sessions where user_id = p_user_id;
$$ language sql;


-- ─────────────────────────────────────────────────────────────
-- Pantry functions
-- ─────────────────────────────────────────────────────────────

-- Single entry point for add / remove / set / delete.
-- Quantities are stored in base units only: g, ml, piece.
-- An item's unit is fixed at first use — adding a different unit
-- raises, and the only way to switch is to delete the item first.
-- Returns the resulting quantity so replies can report actual state.
create or replace function upsert_item(
  p_household_id bigint, p_item text, p_qty numeric, p_unit text, p_action text
) returns numeric as $$
declare existing_unit text; new_qty numeric;
begin
  if p_action = 'delete' then
    delete from pantry where household_id = p_household_id and item = p_item;
    return 0;
  end if;

  if p_unit not in ('g','ml','piece') then
    raise exception 'Invalid unit: %', p_unit;
  end if;

  select unit into existing_unit from pantry
  where household_id = p_household_id and item = p_item;

  if existing_unit is not null and existing_unit <> p_unit then
    raise exception 'Unit mismatch for %: stored as %, got %', p_item, existing_unit, p_unit;
  end if;

  insert into pantry (household_id, item, quantity, unit)
  values (p_household_id, p_item,
          case when p_action = 'remove' then 0 else p_qty end, p_unit)
  on conflict (household_id, item) do update set
    quantity = case
      when p_action = 'add'    then pantry.quantity + p_qty
      when p_action = 'remove' then greatest(pantry.quantity - p_qty, 0)
      else p_qty
    end,
    updated_at = now()
  returning quantity into new_qty;

  return new_qty;
end;
$$ language plpgsql;


-- Subtracts a recipe's ingredients after cooking. Floors at zero.
create or replace function deduct_item(p_household_id bigint, p_item text, p_qty numeric)
returns void as $$
  update pantry set quantity = greatest(quantity - p_qty, 0), updated_at = now()
  where household_id = p_household_id and item = p_item;
$$ language sql;
