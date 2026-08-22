
-- SHUTTERWING v1.4 SPECIES DETAIL + CHOOSE COVER PHOTO

alter table public.passport_entries
add column if not exists is_cover boolean not null default false;

-- Ensure each user's species has one cover image.
with ranked as (
  select
    pe.id,
    row_number() over (
      partition by pe.user_id, lower(trim(pe.species_name))
      order by pe.is_cover desc, pe.first_recorded_at desc
    ) as rn
  from public.passport_entries pe
  where pe.species_name is not null
    and trim(pe.species_name) <> ''
)
update public.passport_entries pe
set is_cover = (r.rn = 1)
from ranked r
where r.id = pe.id;


create or replace function public.get_shutterwing_species_collection()
returns table(
  species_name text,
  sighting_count integer,
  first_seen_at timestamptz,
  last_seen_at timestamptz,
  cover_image_path text,
  is_lifer boolean
)
language sql
security definer
set search_path = ''
as $$
  select
    initcap(trim(pe.species_name)) as species_name,
    count(*)::integer as sighting_count,
    min(pe.first_recorded_at) as first_seen_at,
    max(pe.first_recorded_at) as last_seen_at,
    max(pe.image_path) filter (where pe.is_cover) as cover_image_path,
    bool_or(pe.lifer) as is_lifer
  from public.passport_entries pe
  where pe.user_id = auth.uid()
    and pe.species_name is not null
    and trim(pe.species_name) <> ''
  group by lower(trim(pe.species_name)), initcap(trim(pe.species_name))
  order by species_name;
$$;

revoke all on function public.get_shutterwing_species_collection() from public, anon;
grant execute on function public.get_shutterwing_species_collection() to authenticated;


create or replace function public.get_shutterwing_species_sightings(
  p_species_name text
)
returns table(
  passport_entry_id uuid,
  image_path text,
  recorded_at timestamptz,
  lifer boolean,
  is_cover boolean,
  card_id text,
  card_title text,
  awarded_points integer
)
language sql
security definer
set search_path = ''
as $$
  select
    pe.id,
    pe.image_path,
    pe.first_recorded_at,
    pe.lifer,
    pe.is_cover,
    c.card_id,
    cd.title,
    c.awarded_points
  from public.passport_entries pe
  left join public.claims c
    on c.user_id = pe.user_id
   and c.image_path = pe.image_path
   and lower(trim(c.species_name)) = lower(trim(pe.species_name))
   and c.claim_status = 'accepted'
  left join public.cards cd
    on cd.id = c.card_id
  where pe.user_id = auth.uid()
    and lower(trim(pe.species_name)) = lower(trim(p_species_name))
  order by pe.first_recorded_at desc;
$$;

revoke all on function public.get_shutterwing_species_sightings(text) from public, anon;
grant execute on function public.get_shutterwing_species_sightings(text) to authenticated;


create or replace function public.set_shutterwing_species_cover(
  p_passport_entry_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_species text;
begin
  select pe.species_name
  into v_species
  from public.passport_entries pe
  where pe.id = p_passport_entry_id
    and pe.user_id = auth.uid();

  if v_species is null then
    raise exception 'Passport entry not found';
  end if;

  update public.passport_entries
  set is_cover = false
  where user_id = auth.uid()
    and lower(trim(species_name)) = lower(trim(v_species));

  update public.passport_entries
  set is_cover = true
  where id = p_passport_entry_id
    and user_id = auth.uid();

  return 'cover_updated';
end;
$$;

revoke all on function public.set_shutterwing_species_cover(uuid) from public, anon;
grant execute on function public.set_shutterwing_species_cover(uuid) to authenticated;


-- New accepted species entries become the cover only if that species has no cover yet.
create or replace function public.cast_wing_claim_vote(
  p_claim_id uuid,
  p_accept boolean
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_voter uuid := auth.uid();
  v_game_id uuid;
  v_claim_user uuid;
  v_card_id text;
  v_species text;
  v_image_path text;
  v_wp integer := 0;
  v_multiplier integer := 1;
  v_double_effect uuid;
  v_awarded integer := 0;
  v_note text := 'Base score';
  v_game_mode text;
  v_target_score integer;
  v_new_score integer;
  v_is_lifer boolean := false;
  v_make_cover boolean := false;
begin
  if v_voter is null then raise exception 'You must be signed in'; end if;

  select c.game_id,c.user_id,c.card_id,c.species_name,c.image_path
  into v_game_id,v_claim_user,v_card_id,v_species,v_image_path
  from public.claims c
  where c.id=p_claim_id
  for update;

  if v_game_id is null then raise exception 'Claim not found'; end if;
  if v_claim_user=v_voter then raise exception 'You cannot vote on your own claim'; end if;
  if not private.is_game_member(v_game_id) then raise exception 'Not a member of this game'; end if;

  select g.game_mode,g.target_score
  into v_game_mode,v_target_score
  from public.games g
  where g.id=v_game_id;

  if exists(
    select 1 from public.games g
    where g.id=v_game_id and g.status='finished'
  ) then
    raise exception 'This round has already finished';
  end if;

  insert into public.claim_votes(claim_id,voter_id,vote)
  values(p_claim_id,v_voter,p_accept)
  on conflict on constraint claim_votes_pkey
  do update set vote=excluded.vote,voted_at=now();

  if not p_accept then
    update public.claims
    set claim_status='rejected',resolved_at=now(),awarded_points=0,score_note='Rejected'
    where id=p_claim_id;
    perform private.refill_player_hand(v_game_id,v_claim_user);
    return 'rejected';
  end if;

  select coalesce(c.wing_points,0)
  into v_wp
  from public.cards c
  where c.id=v_card_id;

  select ge.id
  into v_double_effect
  from public.game_effects ge
  where ge.game_id=v_game_id
    and ge.target_user_id=v_claim_user
    and ge.effect_type='double_wing'
    and ge.consumed_at is null
  order by ge.created_at
  limit 1;

  if v_double_effect is not null then
    v_multiplier:=2;
    v_note:='Double Wing ×2';
    update public.game_effects set consumed_at=now() where id=v_double_effect;
  end if;

  v_awarded:=v_wp*v_multiplier;

  update public.claims
  set claim_status='accepted',resolved_at=now(),awarded_points=v_awarded,score_note=v_note
  where id=p_claim_id;

  update public.game_players
  set score=score+v_awarded
  where game_id=v_game_id and user_id=v_claim_user
  returning score into v_new_score;

  update public.profiles
  set feather_points=feather_points+(v_awarded*10)
  where id=v_claim_user;

  if v_species is not null and trim(v_species)<>'' then
    select not exists(
      select 1
      from public.passport_entries pe
      where pe.user_id=v_claim_user
        and lower(trim(pe.species_name))=lower(trim(v_species))
    )
    into v_is_lifer;

    select not exists(
      select 1
      from public.passport_entries pe
      where pe.user_id=v_claim_user
        and lower(trim(pe.species_name))=lower(trim(v_species))
        and pe.is_cover=true
    )
    into v_make_cover;

    insert into public.passport_entries(
      user_id,species_name,image_path,lifer,is_cover
    )
    values(
      v_claim_user,trim(v_species),v_image_path,v_is_lifer,v_make_cover
    );
  end if;

  update public.game_effects
  set consumed_at=now()
  where game_id=v_game_id
    and target_user_id=v_claim_user
    and effect_type in ('camera_jam','flushed')
    and consumed_at is null;

  if v_game_mode='first_to_fifty'
     and v_new_score>=coalesce(v_target_score,50) then
    perform private.record_shutterwing_round_result(v_game_id);
    update public.games set status='finished' where id=v_game_id;
    return case when v_multiplier=2 then 'accepted_double_round_won'
                else 'accepted_round_won' end;
  end if;

  perform private.refill_player_hand(v_game_id,v_claim_user);

  return case when v_multiplier=2 then 'accepted_double'
              else 'accepted' end;
end;
$$;

revoke all on function public.cast_wing_claim_vote(uuid,boolean) from public, anon;
grant execute on function public.cast_wing_claim_vote(uuid,boolean) to authenticated;

notify pgrst, 'reload schema';

select
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as arguments
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in (
    'get_shutterwing_species_collection',
    'get_shutterwing_species_sightings',
    'set_shutterwing_species_cover'
  )
order by p.proname;
