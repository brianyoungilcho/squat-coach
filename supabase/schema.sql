-- Squat Coach pack backend — run once in the Supabase SQL editor.
--
-- The table itself is NOT exposed to the API roles at all. Clients go through
-- two SECURITY DEFINER functions that both require the pack code, so "knowing
-- the code" is enforced server-side as the read/write boundary — a client
-- can't enumerate other packs or touch rows outside the code it presents.
-- Within a pack, members are trusted (it's a group of friends): anyone holding
-- the code can read the pack and upsert rows in it.

create table if not exists public.pack_days (
  pack_code    text        not null check (char_length(pack_code) between 4 and 40),
  member_id    uuid        not null,
  display_name text        not null check (char_length(display_name) between 1 and 40),
  day          date        not null,
  sets         int         not null default 0 check (sets between 0 and 200),
  streak       int         not null default 0 check (streak between 0 and 36500),
  updated_at   timestamptz not null default now(),
  primary key (pack_code, member_id, day)
);

-- Belt and braces: no API-role grants on the table, and RLS default-deny in
-- case a grant ever reappears. (No delete path exists at all: no grant, no
-- policy, and no function deletes.)
alter table public.pack_days enable row level security;
revoke all on table public.pack_days from anon, authenticated;

-- Read a pack's recent rows. STABLE + LIMIT bound; the day window mirrors the
-- write window below.
create or replace function public.pack_fetch(p_code text, p_since date)
returns table (member_id uuid, display_name text, day date, sets int, streak int)
language sql stable security definer set search_path = public
as $$
  select d.member_id, d.display_name, d.day, d.sets, d.streak
  from public.pack_days d
  where d.pack_code = p_code
    and d.day >= p_since
    and d.day <= current_date + 1
  limit 500
$$;

-- Upsert one member-day row. The day window (server clock, UTC) allows ±1 day
-- of client-local skew and blocks history backfill/spam; out-of-window calls
-- are a silent no-op.
create or replace function public.pack_upsert(p_code text, p_member uuid, p_name text,
                                              p_day date, p_sets int, p_streak int)
returns void
language sql security definer set search_path = public
as $$
  insert into public.pack_days (pack_code, member_id, display_name, day, sets, streak)
  select p_code, p_member, p_name, p_day, p_sets, p_streak
  where p_day >= current_date - 7 and p_day <= current_date + 1
  on conflict (pack_code, member_id, day) do update
    set display_name = excluded.display_name,
        sets         = excluded.sets,
        streak       = excluded.streak,
        updated_at   = now()
$$;

grant execute on function public.pack_fetch(text, date) to anon, authenticated;
grant execute on function public.pack_upsert(text, uuid, text, date, int, int) to anon, authenticated;
