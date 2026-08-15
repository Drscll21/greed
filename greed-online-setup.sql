-- =========================================================================
-- $GREED Online — lobby + turn-based multiplayer tables (NEW ONLY)
-- Author: Hermes for drscll21.
-- Scope: creates 3 NEW tables for online play. Does NOT alter or touch
--        existing tables (greed_players, greed_leaderboard, greed_stats).
-- Run this in the Supabase SQL editor (or via psql) once.
-- =========================================================================

-- 1) LOBBY — one row per open/active game room.
create table if not exists public.greed_lobbies (
  id          text primary key,          -- 5-char room code, e.g. 'a7k3q'
  host_name   text not null default '',
  status      text not null default 'lobby',  -- 'lobby' | 'playing' | 'finished'
  started_at  timestamptz,
  created_at  timestamptz not null default now()
);

-- 2) LOBBY PLAYERS — seats in a room (host is seat 0).
create table if not exists public.greed_lobby_players (
  id        bigint generated always as identity primary key,
  lobby_id  text not null references public.greed_lobbies(id) on delete cascade,
  seat      int  not null,
  name      text not null default '',
  is_host   boolean not null default false,
  total     int  not null default 0,     -- running banked total (mirror of game state)
  connected boolean not null default true,
  last_seen timestamptz not null default now(),  -- heartbeats for live connection status
  created_at timestamptz not null default now(),
  unique (lobby_id, seat)
);

-- 3) GAME STATE — the whole current game as JSON for a room (single row).
create table if not exists public.greed_games (
  id         text primary key references public.greed_lobbies(id) on delete cascade,
  state      jsonb not null default '{}'::jsonb,   -- full game snapshot (see client)
  turn_no    int   not null default 0,             -- monotonically increasing guard
  updated_at timestamptz not null default now()
);

-- =========================================================================
-- RLS: enable row level security and open permissive policies for ANON.
-- These apply to the 3 NEW tables ONLY. Existing tables are untouched.
-- (The existing leaderboard already allows anon REST writes, so this matches
--  the project's existing security model.)
-- =========================================================================
alter table public.greed_lobbies       enable row level security;
alter table public.greed_lobby_players enable row level security;
alter table public.greed_games         enable row level security;

create policy "anon lobby full"        on public.greed_lobbies       for all to anon using (true) with check (true);
create policy "anon lobby_players full" on public.greed_lobby_players for all to anon using (true) with check (true);
create policy "anon games full"         on public.greed_games         for all to anon using (true) with check (true);

-- Grant the anon role the standard privileges on these tables.
grant select, insert, update, delete on public.greed_lobbies       to anon;
grant select, insert, update, delete on public.greed_lobby_players to anon;
grant select, insert, update, delete on public.greed_games         to anon;