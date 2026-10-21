-- Exécuter dans Supabase > SQL Editor avant d'activer inscription/connexion.
-- Le rôle propriétaire doit être attribué manuellement depuis le SQL Editor,
-- après la création de son compte. Les inscriptions publiques deviennent client.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null default '',
  phone text,
  role text not null default 'client'
    check (role in ('proprietaire', 'organisateur', 'personnel', 'client')),
  role_expires_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.profiles
  add column if not exists role_expires_at timestamptz;
alter table public.profiles
  add column if not exists phone text;

alter table public.profiles enable row level security;

revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (full_name, phone) on public.profiles to authenticated;
revoke update (role) on public.profiles from anon, authenticated;

drop policy if exists "Users can read their own profile" on public.profiles;
create policy "Users can read their own profile"
  on public.profiles for select
  to authenticated
  using (id = (select auth.uid()));

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
  on public.profiles for update
  to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

drop index if exists public.profiles_single_owner;

create table if not exists public.partner_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  company_name text not null check (length(trim(company_name)) between 1 and 100),
  message text,
  status text not null default 'en_attente'
    check (status in ('en_attente', 'approuvee', 'refusee')),
  created_at timestamptz not null default now()
);
create index if not exists partner_requests_user_created on public.partner_requests (user_id, created_at desc);
alter table public.partner_requests enable row level security;
revoke all on public.partner_requests from anon, authenticated;
grant select, insert on public.partner_requests to authenticated;
grant update (status) on public.partner_requests to authenticated;
drop policy if exists "Users can read their partner requests" on public.partner_requests;
create policy "Users can read their partner requests" on public.partner_requests for select to authenticated
  using (user_id = (select auth.uid()) or exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'proprietaire'));
drop policy if exists "Users can create partner requests" on public.partner_requests;
create policy "Users can create partner requests" on public.partner_requests for insert to authenticated
  with check (user_id = (select auth.uid()));
drop policy if exists "Owner can update partner requests" on public.partner_requests;
create policy "Owner can update partner requests" on public.partner_requests for update to authenticated
  using (exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'proprietaire'));

create table if not exists public.settings (
  key text primary key, value text not null default '', updated_at timestamptz not null default now()
);
insert into public.settings (key, value) values
  ('public_test_mode', 'true'), ('public_receiver_mpesa', ''),
  ('public_receiver_airtel', ''), ('public_receiver_orange', '')
on conflict (key) do nothing;
alter table public.settings enable row level security;
revoke all on public.settings from anon, authenticated;
grant select, insert, update on public.settings to authenticated;
drop policy if exists "Authenticated users can read settings" on public.settings;
create policy "Authenticated users can read settings" on public.settings for select to authenticated using (true);
drop policy if exists "Owner can manage settings" on public.settings;
create policy "Owner can manage settings" on public.settings for all to authenticated
  using (exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'proprietaire'))
  with check (exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'proprietaire'));

create or replace function public.guard_profile_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and old.role = 'proprietaire' then
    raise exception 'The owner profile cannot be deleted';
  end if;

  if tg_op = 'UPDATE' and new.role is distinct from old.role then
    if old.role = 'proprietaire' then
      raise exception 'The owner role cannot be changed';
    end if;

    if auth.uid() is not null
       and not exists (
         select 1 from public.profiles owner_profile
         where owner_profile.id = auth.uid()
           and owner_profile.role = 'proprietaire'
       )
       and coalesce(current_setting('app.allow_role_management', true), '') <> 'on' then
      raise exception 'Profile roles cannot be changed by an authenticated user';
    end if;

    if new.role = 'proprietaire'
       and exists (
         select 1 from public.profiles
         where role = 'proprietaire' and id <> old.id
       ) then
      raise exception 'An owner account already exists';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- Le propriétaire peut autoriser un compte existant à scanner les billets.
-- La fonction est appelée depuis l'administration et protège elle-même l'accès.
drop function if exists public.set_staff_role(text, text);
create function public.set_staff_role(p_email text, p_role text default 'personnel')
returns table (id uuid, full_name text, email text, role text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.profiles owner_profile
    where owner_profile.id = auth.uid() and owner_profile.role = 'proprietaire'
  ) then
    raise exception 'Accès réservé au propriétaire';
  end if;

  if lower(coalesce(p_role, '')) not in ('personnel', 'client') then
    raise exception 'Rôle invalide';
  end if;

  perform set_config('app.allow_role_management', 'on', true);
  perform set_config('biso.allow_role_change', 'on', true);
  update public.profiles p
  set role = lower(p_role)
  from auth.users u
  where p.id = u.id
    and lower(u.email) = lower(trim(coalesce(p_email, '')));

  if not found then
    raise exception 'Aucun compte trouvé pour cet email';
  end if;

  return query
    select p.id, p.full_name::text, u.email::text, p.role::text
    from public.profiles p
    join auth.users u on u.id = p.id
    where lower(u.email) = lower(trim(coalesce(p_email, '')));
end;
$$;
revoke all on function public.set_staff_role(text, text) from public;
grant execute on function public.set_staff_role(text, text) to authenticated;

-- Gestion de plusieurs administrateurs. Le rôle interne reste proprietaire
-- afin de conserver les mêmes droits dans les règles RLS existantes.
drop function if exists public.list_admins();
create function public.list_admins()
returns table (id uuid, full_name text, email text, created_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'proprietaire') then
    raise exception 'Accès réservé aux administrateurs';
  end if;
  return query
    select p.id, p.full_name::text, u.email::text, u.created_at::timestamptz
    from public.profiles p join auth.users u on u.id = p.id
    where p.role = 'proprietaire' order by u.created_at;
end;
$$;
revoke all on function public.list_admins() from public;
grant execute on function public.list_admins() to authenticated;

drop function if exists public.set_admin_role(text, boolean);
create function public.set_admin_role(p_email text, p_is_admin boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid;
  v_admin_count integer;
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'proprietaire') then
    raise exception 'Accès réservé aux administrateurs';
  end if;
  select p.id into v_target
  from public.profiles p join auth.users u on u.id = p.id
  where lower(u.email) = lower(trim(coalesce(p_email, '')));
  if v_target is null then raise exception 'Aucun compte trouvé pour cet email'; end if;
  if not p_is_admin and v_target = auth.uid() then raise exception 'Vous ne pouvez pas retirer votre propre accès'; end if;
  select count(*) into v_admin_count from public.profiles where role = 'proprietaire';
  if not p_is_admin and v_admin_count <= 1 then raise exception 'Il faut conserver au moins un administrateur'; end if;
  perform set_config('app.allow_role_management', 'on', true);
  update public.profiles set role = case when p_is_admin then 'proprietaire' else 'client' end where id = v_target;
end;
$$;
revoke all on function public.set_admin_role(text, boolean) from public;
grant execute on function public.set_admin_role(text, boolean) to authenticated;

drop function if exists public.owner_export_tickets();
create function public.owner_export_tickets()
returns table (
  event_title text,
  ticket_code text,
  holder_name text,
  buyer_name text,
  amount numeric,
  currency text,
  ticket_status text,
  scanned_at timestamptz,
  scanned_gate text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'proprietaire') then
    raise exception 'Accès réservé aux administrateurs';
  end if;
  return query
    select e.title::text, t.code::text, t.holder_name::text,
      buyer.full_name::text, ol.unit_price, o.currency::text, t.status::text,
      t.scanned_at, t.scanned_gate::text, t.created_at
    from public.tickets t
    join public.events e on e.id = t.event_id
    join public.order_lines ol on ol.id = t.order_line_id
    join public.orders o on o.id = t.order_id
    left join public.profiles buyer on buyer.id = o.user_id
    order by t.created_at desc;
end;
$$;
revoke all on function public.owner_export_tickets() from public;
grant execute on function public.owner_export_tickets() to authenticated;

-- Les rôles sont gérés uniquement par set_staff_role.
-- Les utilisateurs authentifiés n'ont pas le privilège UPDATE sur la colonne role.
drop trigger if exists guard_profile_role on public.profiles;

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, phone, role)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), ''),
    nullif(trim(new.raw_user_meta_data ->> 'phone'), ''),
    'client'
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.create_profile_for_new_user();

update public.profiles p
set phone = nullif(trim(u.raw_user_meta_data ->> 'phone'), '')
from auth.users u
where p.id = u.id and p.phone is null
  and nullif(trim(u.raw_user_meta_data ->> 'phone'), '') is not null;

create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 1 and 120),
  description text,
  starts_at timestamptz not null,
  ends_at timestamptz,
  capacity integer not null check (capacity > 0),
  currency text not null default 'USD' check (currency in ('USD', 'CDF')),
  venue text,
  city text,
  poster_url text,
  require_ticket_photo boolean not null default false,
  status text not null default 'brouillon'
    check (status in ('brouillon', 'en_attente', 'publie', 'complet', 'termine', 'annule')),
  created_by uuid not null default auth.uid() references public.profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.events
  add column if not exists require_ticket_photo boolean not null default false;
alter table public.events
  add column if not exists ends_at timestamptz;
alter table public.order_lines
  add column if not exists holder_email text;
alter table public.tickets
  add column if not exists holder_email text;
alter table public.staff_assignments
  add column if not exists active_until timestamptz;
alter table public.events
  add column if not exists created_by uuid references public.profiles (id) on delete restrict;
alter table public.events
  alter column created_by set default auth.uid();

create index if not exists events_public_schedule
  on public.events (starts_at)
  where status in ('publie', 'complet');

create table if not exists public.ticket_categories (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  perks text,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (event_id, name),
  unique (id, event_id)
);

create table if not exists public.ticket_lots (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  category_id uuid not null,
  name text not null check (length(trim(name)) between 1 and 80),
  price numeric(12, 2) not null check (price >= 0),
  quantity integer not null check (quantity > 0),
  sold integer not null default 0 check (sold >= 0),
  held integer not null default 0 check (held >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (sold + held <= quantity),
  foreign key (category_id, event_id)
    references public.ticket_categories (id, event_id) on delete cascade
);

create index if not exists ticket_categories_event_order
  on public.ticket_categories (event_id, sort_order);
create index if not exists ticket_lots_event_active
  on public.ticket_lots (event_id, active);

alter table public.events enable row level security;
alter table public.ticket_categories enable row level security;
alter table public.ticket_lots enable row level security;

revoke all on public.events, public.ticket_categories, public.ticket_lots from anon, authenticated;
grant select on public.events, public.ticket_categories, public.ticket_lots to anon, authenticated;
grant insert (title, description, starts_at, capacity, currency, venue, city, poster_url, require_ticket_photo)
  on public.events to authenticated;
grant update (title, description, starts_at, capacity, currency, venue, city, poster_url, require_ticket_photo, status)
  on public.events to authenticated;
grant insert (event_id, name, perks, sort_order),
  update (name, perks, sort_order) on public.ticket_categories to authenticated;
grant insert (event_id, category_id, name, price, quantity, active),
  update (name, price, quantity, active) on public.ticket_lots to authenticated;

drop policy if exists "Public can read listed events" on public.events;
create policy "Public can read listed events"
  on public.events for select
  to anon, authenticated
  using (status in ('publie', 'complet') and starts_at >= now());

drop policy if exists "Owner can manage events" on public.events;
create policy "Owner can manage events"
  on public.events for all
  to authenticated
  using (exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'proprietaire'
  ))
  with check (exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'proprietaire'
  ));

drop policy if exists "Organizers can read their own events" on public.events;
create policy "Organizers can read their own events"
  on public.events for select
  to authenticated
  using (
    created_by = (select auth.uid())
    and exists (
      select 1 from public.profiles
      where id = (select auth.uid())
        and role = 'organisateur'
        and (role_expires_at is null or role_expires_at > now())
    )
  );

drop policy if exists "Organizers can propose their own events" on public.events;
create policy "Organizers can propose their own events"
  on public.events for insert
  to authenticated
  with check (
    created_by = (select auth.uid())
    and status = 'brouillon'
    and exists (
      select 1 from public.profiles
      where id = (select auth.uid())
        and role = 'organisateur'
        and (role_expires_at is null or role_expires_at > now())
    )
  );

drop policy if exists "Organizers can update their own proposals" on public.events;
create policy "Organizers can update their own proposals"
  on public.events for update
  to authenticated
  using (
    created_by = (select auth.uid())
    and status in ('brouillon', 'en_attente')
    and exists (
      select 1 from public.profiles
      where id = (select auth.uid())
        and role = 'organisateur'
        and (role_expires_at is null or role_expires_at > now())
    )
  )
  with check (
    created_by = (select auth.uid())
    and status in ('brouillon', 'en_attente')
    and exists (
      select 1 from public.profiles
      where id = (select auth.uid())
        and role = 'organisateur'
        and (role_expires_at is null or role_expires_at > now())
    )
  );

drop policy if exists "Public can read categories for listed events" on public.ticket_categories;
create policy "Public can read categories for listed events"
  on public.ticket_categories for select
  to anon, authenticated
  using (exists (
    select 1 from public.events
    where id = event_id and status in ('publie', 'complet') and starts_at >= now()
  ));

drop policy if exists "Owner can manage event categories" on public.ticket_categories;
create policy "Owner can manage event categories"
  on public.ticket_categories for all
  to authenticated
  using (exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'proprietaire'
  ))
  with check (exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'proprietaire'
  ));

drop policy if exists "Organizers can manage categories for their proposals" on public.ticket_categories;
create policy "Organizers can manage categories for their proposals"
  on public.ticket_categories for all
  to authenticated
  using (exists (
    select 1 from public.events e
    join public.profiles p on p.id = (select auth.uid())
    where e.id = event_id
      and e.created_by = (select auth.uid())
      and e.status in ('brouillon', 'en_attente')
      and p.role = 'organisateur'
      and (p.role_expires_at is null or p.role_expires_at > now())
  ))
  with check (exists (
    select 1 from public.events e
    join public.profiles p on p.id = (select auth.uid())
    where e.id = event_id
      and e.created_by = (select auth.uid())
      and e.status in ('brouillon', 'en_attente')
      and p.role = 'organisateur'
      and (p.role_expires_at is null or p.role_expires_at > now())
  ));

drop policy if exists "Public can read lots for listed events" on public.ticket_lots;
create policy "Public can read lots for listed events"
  on public.ticket_lots for select
  to anon, authenticated
  using (active and exists (
    select 1 from public.events
    where id = event_id and status in ('publie', 'complet') and starts_at >= now()
  ));

drop policy if exists "Owner can manage event lots" on public.ticket_lots;
create policy "Owner can manage event lots"
  on public.ticket_lots for all
  to authenticated
  using (exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'proprietaire'
  ))
  with check (exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'proprietaire'
  ));

drop policy if exists "Organizers can manage lots for their proposals" on public.ticket_lots;
create policy "Organizers can manage lots for their proposals"
  on public.ticket_lots for all
  to authenticated
  using (exists (
    select 1 from public.events e
    join public.profiles p on p.id = (select auth.uid())
    where e.id = event_id
      and e.created_by = (select auth.uid())
      and e.status in ('brouillon', 'en_attente')
      and p.role = 'organisateur'
      and (p.role_expires_at is null or p.role_expires_at > now())
  ))
  with check (exists (
    select 1 from public.events e
    join public.profiles p on p.id = (select auth.uid())
    where e.id = event_id
      and e.created_by = (select auth.uid())
      and e.status in ('brouillon', 'en_attente')
      and p.role = 'organisateur'
      and (p.role_expires_at is null or p.role_expires_at > now())
  ));

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles (id) on delete restrict,
  event_id uuid not null references public.events (id) on delete restrict,
  total numeric(12, 2) not null check (total >= 0),
  currency text not null check (currency in ('USD', 'CDF')),
  status text not null default 'en_attente'
    check (status in ('en_attente', 'paye', 'annule', 'expire')),
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  created_at timestamptz not null default now()
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  amount numeric(12, 2) not null check (amount > 0),
  currency text not null check (currency in ('USD', 'CDF')),
  method text not null check (method in ('mpesa', 'airtel', 'orange', 'test')),
  network text, transfer_code text, phone text,
  status text not null default 'en_attente' check (status in ('en_attente', 'a_verifier', 'reussi', 'echoue', 'expire')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists payments_order_created on public.payments (order_id, created_at desc);
create index if not exists payments_status_created on public.payments (status, created_at desc);

create table if not exists public.incoming_transactions (
  id uuid primary key default gen_random_uuid(),
  network text not null check (network in ('mpesa', 'airtel', 'orange')),
  transfer_code text not null, amount numeric(12, 2) not null check (amount > 0),
  currency text not null check (currency in ('USD', 'CDF')),
  received_at timestamptz not null default now(), used boolean not null default false,
  used_at timestamptz, unique (network, transfer_code)
);
create index if not exists incoming_transactions_received on public.incoming_transactions (received_at desc);

create table if not exists public.order_lines (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  lot_id uuid not null references public.ticket_lots (id) on delete restrict,
  holder_name text not null check (length(trim(holder_name)) between 1 and 80),
  holder_phone text,
  holder_email text,
  photo_path text,
  unit_price numeric(12, 2) not null check (unit_price >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.tickets (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  order_line_id uuid not null unique references public.order_lines (id) on delete restrict,
  order_id uuid not null references public.orders (id) on delete restrict,
  event_id uuid not null references public.events (id) on delete restrict,
  lot_id uuid not null references public.ticket_lots (id) on delete restrict,
  owner_id uuid not null references public.profiles (id) on delete restrict,
  holder_name text not null,
  holder_phone text,
  holder_email text,
  photo_path text,
  status text not null default 'en_attente_paiement'
    check (status in ('valide', 'en_attente_paiement', 'en_attente_confirmation', 'utilise', 'annule', 'bloque')),
  is_free boolean not null default false,
  scanned_at timestamptz,
  scanned_by uuid references public.profiles (id) on delete set null,
  scanned_gate text,
  created_at timestamptz not null default now()
);

create table if not exists public.staff_assignments (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  gate text not null default 'Porte 1',
  active_until timestamptz,
  created_at timestamptz not null default now(),
  unique (event_id, user_id)
);

create table if not exists public.incidents (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.tickets (id) on delete restrict,
  event_id uuid not null references public.events (id) on delete restrict,
  reported_by uuid not null references public.profiles (id) on delete restrict,
  present_person_name text not null check (length(trim(present_person_name)) between 1 and 80),
  status text not null default 'ouvert' check (status in ('ouvert', 'autorise', 'refuse')),
  created_at timestamptz not null default now(),
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  decision_note text
);

create index if not exists orders_user_created on public.orders (user_id, created_at desc);
create index if not exists orders_pending_expiry on public.orders (expires_at) where status = 'en_attente';
create index if not exists order_lines_order on public.order_lines (order_id);
create index if not exists tickets_owner_created on public.tickets (owner_id, created_at desc);
create index if not exists tickets_event_status on public.tickets (event_id, status);

alter table public.orders enable row level security;
alter table public.payments enable row level security;
alter table public.incoming_transactions enable row level security;
alter table public.order_lines enable row level security;
alter table public.tickets enable row level security;
alter table public.staff_assignments enable row level security;
alter table public.incidents enable row level security;

revoke all on public.orders, public.order_lines, public.tickets, public.staff_assignments, public.incidents from anon, authenticated;
grant select on public.orders, public.order_lines, public.tickets, public.staff_assignments, public.incidents to authenticated;
revoke all on public.payments, public.incoming_transactions from anon, authenticated;
grant select on public.payments to authenticated;
grant select, insert on public.incoming_transactions to authenticated;
drop policy if exists "Users and owner can read payments" on public.payments;
create policy "Users and owner can read payments" on public.payments for select to authenticated using (exists (
  select 1 from public.orders o where o.id = order_id and (o.user_id = (select auth.uid()) or exists (
    select 1 from public.profiles where id = (select auth.uid()) and role = 'proprietaire'))));
drop policy if exists "Owner can read incoming transactions" on public.incoming_transactions;
create policy "Owner can read incoming transactions" on public.incoming_transactions for select to authenticated using (exists (
  select 1 from public.profiles where id = (select auth.uid()) and role = 'proprietaire'));
drop policy if exists "Owner can insert incoming transactions" on public.incoming_transactions;
create policy "Owner can insert incoming transactions" on public.incoming_transactions for insert to authenticated with check (exists (
  select 1 from public.profiles where id = (select auth.uid()) and role = 'proprietaire'));

drop policy if exists "Buyers can read their orders" on public.orders;
create policy "Buyers can read their orders"
  on public.orders for select to authenticated
  using (user_id = (select auth.uid()) or exists (
    select 1 from public.profiles where id = (select auth.uid()) and role = 'proprietaire'
  ));

drop policy if exists "Buyers can read their order lines" on public.order_lines;
create policy "Buyers can read their order lines"
  on public.order_lines for select to authenticated
  using (exists (
    select 1 from public.orders o
    where o.id = order_id and (
      o.user_id = (select auth.uid()) or exists (
        select 1 from public.profiles where id = (select auth.uid()) and role = 'proprietaire'
      )
    )
  ));

drop policy if exists "Ticket owners can read their tickets" on public.tickets;
create policy "Ticket owners can read their tickets"
  on public.tickets for select to authenticated
  using (owner_id = (select auth.uid()));

drop policy if exists "Owners can manage event staff" on public.staff_assignments;
create policy "Owners can manage event staff"
  on public.staff_assignments for all to authenticated
  using (exists (
    select 1 from public.profiles p
    join public.events e on e.id = event_id
    where p.id = (select auth.uid())
      and (
        p.role = 'proprietaire'
        or (e.created_by = (select auth.uid()) and p.role = 'organisateur'
          and (p.role_expires_at is null or p.role_expires_at > now()))
      )
  ))
  with check (exists (
    select 1 from public.profiles p
    join public.events e on e.id = event_id
    join public.profiles staff on staff.id = user_id
    where p.id = (select auth.uid())
      and (
        p.role = 'proprietaire'
        or (e.created_by = (select auth.uid()) and p.role = 'organisateur'
          and (p.role_expires_at is null or p.role_expires_at > now()))
      )
      and staff.role = 'personnel'
  ));

drop policy if exists "Staff can read their event assignments" on public.staff_assignments;
create policy "Staff can read their event assignments"
  on public.staff_assignments for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "Incident reporters can read their reports" on public.incidents;
create policy "Incident reporters can read their reports"
  on public.incidents for select to authenticated
  using (reported_by = (select auth.uid()));

drop policy if exists "Event owners can read incident reports" on public.incidents;
create policy "Event owners can read incident reports"
  on public.incidents for select to authenticated
  using (exists (
    select 1 from public.events e
    join public.profiles p on p.id = (select auth.uid())
    where e.id = event_id
      and (
        p.role = 'proprietaire'
        or (e.created_by = (select auth.uid()) and p.role = 'organisateur'
          and (p.role_expires_at is null or p.role_expires_at > now()))
      )
  ));

drop function if exists public.assign_staff(text, uuid, text);
create function public.assign_staff(p_email text, p_event_id uuid, p_gate text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff_id uuid;
  v_assignment_id uuid;
begin
  if not (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'proprietaire')
    or exists (
      select 1 from public.events e join public.profiles p on p.id = auth.uid()
      where e.id = p_event_id and e.created_by = auth.uid()
        and p.role = 'organisateur' and (p.role_expires_at is null or p.role_expires_at > now())
    )
  ) then raise exception 'Vous ne pouvez pas affecter du personnel à cet événement'; end if;
  select p.id into v_staff_id
  from auth.users u join public.profiles p on p.id = u.id
  where lower(u.email) = lower(trim(coalesce(p_email, '')))
    and p.role = 'personnel';
  if v_staff_id is null then
    raise exception 'Aucun compte personnel trouvé pour cet email';
  end if;
  insert into public.staff_assignments (event_id, user_id, gate, active_until)
  values (p_event_id, v_staff_id, left(coalesce(nullif(trim(p_gate), ''), 'Porte 1'), 30),
          (select ends_at from public.events where id = p_event_id))
  on conflict (event_id, user_id) do update
    set gate = excluded.gate
  returning id into v_assignment_id;
  return v_assignment_id;
end;
$$;

drop function if exists public.list_staff(uuid);
create function public.list_staff(p_event_id uuid)
returns table (id uuid, full_name text, email text, phone text, gate text, active_until timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'proprietaire')
    or exists (
      select 1 from public.events e join public.profiles p on p.id = auth.uid()
      where e.id = p_event_id and e.created_by = auth.uid()
        and p.role = 'organisateur' and (p.role_expires_at is null or p.role_expires_at > now())
    )
  ) then raise exception 'Vous ne pouvez pas consulter le personnel de cet événement'; end if;
  return query
    select s.id, p.full_name, u.email, p.phone, s.gate, s.active_until
    from public.staff_assignments s
    join public.profiles p on p.id = s.user_id
    join auth.users u on u.id = s.user_id
    where s.event_id = p_event_id
    order by p.full_name;
end;
$$;

create or replace function public.remove_staff(p_assignment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_id uuid;
begin
  select event_id into v_event_id
  from public.staff_assignments where id = p_assignment_id;
  if v_event_id is null then raise exception 'Affectation introuvable'; end if;
  if not (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'proprietaire')
    or exists (
      select 1 from public.events e join public.profiles p on p.id = auth.uid()
      where e.id = v_event_id and e.created_by = auth.uid()
        and p.role = 'organisateur' and (p.role_expires_at is null or p.role_expires_at > now())
    )
  ) then raise exception 'Vous ne pouvez pas retirer ce membre du personnel'; end if;
  delete from public.staff_assignments where id = p_assignment_id;
end;
$$;

drop function if exists public.remove_staff_role(text);
create function public.remove_staff_role(p_email text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_user_id uuid;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'proprietaire') then
    raise exception 'Accès réservé aux administrateurs';
  end if;
  select u.id into v_user_id from auth.users u
  where lower(u.email) = lower(trim(coalesce(p_email, '')));
  if v_user_id is null then raise exception 'Aucun compte trouvé pour cet email'; end if;
  delete from public.staff_assignments where user_id = v_user_id;
  perform set_config('app.allow_role_management', 'on', true);
  perform set_config('biso.allow_role_change', 'on', true);
  update public.profiles set role = 'client' where id = v_user_id and role = 'personnel';
end;
$$;
revoke all on function public.remove_staff_role(text) from public, anon;
grant execute on function public.remove_staff_role(text) to authenticated;

create or replace function public.expire_pending_orders()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  with expired as (
    update public.orders
    set status = 'expire'
    where status = 'en_attente' and expires_at <= now()
    returning id
  ), released as (
    select ol.lot_id, count(*)::integer as amount
    from public.order_lines ol
    join expired e on e.id = ol.order_id
    group by ol.lot_id
  )
  update public.ticket_lots l
  set held = greatest(0, l.held - released.amount)
  from released
  where l.id = released.lot_id;

  update public.tickets t
  set status = 'annule'
  where t.order_id in (select id from public.orders where status = 'expire')
    and t.status = 'en_attente_paiement';
end;
$$;

create or replace function public.create_order(p_event_id uuid, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_event public.events%rowtype;
  v_line jsonb;
  v_lot public.ticket_lots%rowtype;
  v_order_id uuid;
  v_line_id uuid;
  v_photo text;
  v_name text;
  v_phone text;
  v_email text;
  v_total numeric(12, 2) := 0;
begin
  if v_user is null then raise exception 'Connexion requise'; end if;
  if p_lines is null or jsonb_typeof(p_lines) is distinct from 'array' then
    raise exception 'La liste de billets est invalide';
  end if;
  if jsonb_array_length(p_lines) < 1 or jsonb_array_length(p_lines) > 10 then
    raise exception 'Le panier doit contenir entre 1 et 10 billets';
  end if;

  perform public.expire_pending_orders();
  select * into v_event from public.events
  where id = p_event_id and status = 'publie' and starts_at > now()
  for update;
  if not found then raise exception 'La vente de cet événement est fermée'; end if;

  for v_line in
    select value from jsonb_array_elements(p_lines) as x(value)
    order by value ->> 'lot_id'
  loop
    v_name := trim(coalesce(v_line ->> 'holder_name', ''));
    v_phone := nullif(trim(coalesce(v_line ->> 'holder_phone', '')), '');
    v_email := nullif(lower(trim(coalesce(v_line ->> 'holder_email', ''))), '');
    if v_email is null or length(v_email) > 254 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      raise exception 'E-mail du détenteur invalide';
    end if;
    v_photo := nullif(trim(coalesce(v_line ->> 'photo_path', '')), '');
    if length(v_name) < 1 or length(v_name) > 80 then
      raise exception 'Le nom du détenteur est invalide';
    end if;
    if v_event.require_ticket_photo and v_photo is null then
      raise exception 'Une photo est obligatoire pour cet événement';
    end if;
    if v_photo is not null and (
      split_part(v_photo, '/', 1) <> v_user::text
      or position('..' in v_photo) > 0
      or not exists (
        select 1 from storage.objects
        where bucket_id = 'ticket-photos' and name = v_photo
      )
    ) then raise exception 'La photo du billet est invalide'; end if;

    select * into v_lot from public.ticket_lots
    where id = (v_line ->> 'lot_id')::uuid
      and event_id = p_event_id and active
    for update;
    if not found then raise exception 'Un lot de billets n’est plus disponible'; end if;
    if v_lot.quantity - v_lot.sold - v_lot.held < 1 then
      raise exception 'Un lot de billets vient d’être épuisé';
    end if;
    update public.ticket_lots set held = held + 1 where id = v_lot.id;
    v_total := v_total + v_lot.price;
  end loop;

  insert into public.orders (user_id, event_id, total, currency)
  values (v_user, p_event_id, v_total, v_event.currency)
  returning id into v_order_id;

  for v_line in select value from jsonb_array_elements(p_lines) as x(value)
  loop
    select * into v_lot from public.ticket_lots
    where id = (v_line ->> 'lot_id')::uuid and event_id = p_event_id;
    v_name := trim(v_line ->> 'holder_name');
    v_phone := nullif(trim(coalesce(v_line ->> 'holder_phone', '')), '');
    v_email := nullif(lower(trim(coalesce(v_line ->> 'holder_email', ''))), '');
    v_photo := nullif(trim(coalesce(v_line ->> 'photo_path', '')), '');
    insert into public.order_lines (order_id, lot_id, holder_name, holder_phone, holder_email, photo_path, unit_price)
    values (v_order_id, v_lot.id, v_name, v_phone, v_email, v_photo, v_lot.price)
    returning id into v_line_id;
    insert into public.tickets (
      code, order_line_id, order_id, event_id, lot_id, owner_id,
      holder_name, holder_phone, holder_email, photo_path, is_free
    ) values (
      replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
      v_line_id, v_order_id, p_event_id, v_lot.id, v_user,
      v_name, v_phone, v_email, v_photo, v_lot.price = 0
    );
  end loop;

  if v_total = 0 then
    update public.orders set status = 'paye' where id = v_order_id;
    update public.tickets set status = 'valide' where order_id = v_order_id;
    update public.ticket_lots l
    set held = l.held - sold.amount, sold = l.sold + sold.amount
    from (
      select lot_id, count(*)::integer as amount
      from public.order_lines where order_id = v_order_id group by lot_id
    ) sold
    where l.id = sold.lot_id;
  end if;
  return v_order_id;
end;
$$;

drop function if exists public.settle_payment(uuid);
create function public.settle_payment(p_payment_id uuid) returns void language plpgsql security definer set search_path = '' as $$
declare v_payment public.payments%rowtype; v_order public.orders%rowtype;
begin
  select * into v_payment from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Paiement introuvable'; end if;
  select * into v_order from public.orders where id = v_payment.order_id for update;
  if not found then raise exception 'Commande introuvable'; end if;
  if v_order.status = 'paye' then update public.payments set status = 'reussi', updated_at = now() where id = p_payment_id; return; end if;
  if v_order.status <> 'en_attente' or v_order.expires_at <= now() then raise exception 'Cette commande a expiré'; end if;
  update public.orders set status = 'paye' where id = v_order.id;
  update public.tickets set status = 'valide' where order_id = v_order.id and status = 'en_attente_paiement';
  update public.ticket_lots l set held = l.held - sold.amount, sold = l.sold + sold.amount
  from (select lot_id, count(*)::integer amount from public.order_lines where order_id = v_order.id group by lot_id) sold where l.id = sold.lot_id;
  update public.payments set status = 'reussi', updated_at = now() where id = p_payment_id;
end; $$;

drop function if exists public.start_payment(uuid, text, text);
create function public.start_payment(p_order_id uuid, p_method text, p_phone text default null) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_order public.orders%rowtype; v_id uuid;
begin
  perform public.expire_pending_orders();
  select * into v_order from public.orders where id = p_order_id and user_id = auth.uid() for update;
  if not found or v_order.status <> 'en_attente' or v_order.expires_at <= now() then raise exception 'Cette commande a expiré ou n’est plus disponible'; end if;
  if p_method is null or p_method not in ('mpesa','airtel','orange','test') then raise exception 'Moyen de paiement invalide'; end if;
  insert into public.payments(order_id,amount,currency,method,network,phone) values(v_order.id,v_order.total,v_order.currency,p_method,nullif(p_method,'test'),nullif(trim(coalesce(p_phone,'')),'')) returning id into v_id;
  return v_id;
end; $$;

drop function if exists public.submit_transfer_code(uuid, text, text, text);
create function public.submit_transfer_code(p_order_id uuid, p_network text, p_code text, p_phone text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_order public.orders%rowtype; v_id uuid; v_tx public.incoming_transactions%rowtype;
begin
  perform public.expire_pending_orders();
  select * into v_order from public.orders where id = p_order_id and user_id = auth.uid() for update;
  if not found then raise exception 'Commande introuvable'; end if;
  if v_order.status <> 'en_attente' or v_order.expires_at <= now() then return jsonb_build_object('status','remboursement'); end if;
  if p_network not in ('mpesa','airtel','orange') or length(trim(coalesce(p_code,''))) < 3 or length(trim(p_code)) > 40 then raise exception 'Code de transfert invalide'; end if;
  insert into public.payments(order_id,amount,currency,method,network,transfer_code,phone,status) values(v_order.id,v_order.total,v_order.currency,p_network,p_network,trim(p_code),nullif(trim(coalesce(p_phone,'')),''),'a_verifier') returning id into v_id;
  select * into v_tx from public.incoming_transactions where network=p_network and transfer_code=trim(p_code) and amount=v_order.total and currency=v_order.currency and not used for update;
  if found then update public.incoming_transactions set used=true,used_at=now() where id=v_tx.id; perform public.settle_payment(v_id); return jsonb_build_object('payment_id',v_id,'status','confirme'); end if;
  return jsonb_build_object('payment_id',v_id,'status','a_verifier');
end; $$;

drop function if exists public.simulate_payment_success(uuid);
create function public.simulate_payment_success(p_payment_id uuid) returns void language plpgsql security definer set search_path = '' as $$
declare v public.payments%rowtype;
begin
  select p.* into v from public.payments p join public.orders o on o.id=p.order_id where p.id=p_payment_id and (o.user_id=auth.uid() or exists(select 1 from public.profiles where id=auth.uid() and role='proprietaire')) for update;
  if not found or v.method <> 'test' then raise exception 'Paiement de test introuvable'; end if;
  perform public.settle_payment(p_payment_id);
end; $$;

drop function if exists public.approve_code_payment(uuid);
create function public.approve_code_payment(p_payment_id uuid) returns void language plpgsql security definer set search_path = '' as $$
declare v public.payments%rowtype;
begin
  if not exists(select 1 from public.profiles where id=auth.uid() and role='proprietaire') then raise exception 'Accès réservé au propriétaire'; end if;
  select * into v from public.payments where id=p_payment_id for update;
  if not found or v.status <> 'a_verifier' then raise exception 'Ce paiement n’est plus à vérifier'; end if;
  update public.incoming_transactions set used=true,used_at=now() where network=v.network and transfer_code=v.transfer_code and amount=v.amount and currency=v.currency and not used;
  perform public.settle_payment(p_payment_id);
end; $$;

drop function if exists public.reject_code_payment(uuid);
create function public.reject_code_payment(p_payment_id uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.profiles where id=auth.uid() and role='proprietaire') then raise exception 'Accès réservé au propriétaire'; end if;
  update public.payments set status='echoue',updated_at=now() where id=p_payment_id and status='a_verifier';
  if not found then raise exception 'Ce paiement n’est plus à vérifier'; end if;
end; $$;

create or replace function public.match_incoming_transaction() returns trigger language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  select p.id into v_id from public.payments p join public.orders o on o.id=p.order_id where p.status='a_verifier' and p.network=new.network and p.transfer_code=new.transfer_code and p.amount=new.amount and p.currency=new.currency and o.status='en_attente' and o.expires_at>now() order by p.created_at limit 1;
  if v_id is not null then update public.incoming_transactions set used=true,used_at=now() where id=new.id; perform public.settle_payment(v_id); end if;
  return new;
end; $$;
drop trigger if exists match_incoming_transaction on public.incoming_transactions;
create trigger match_incoming_transaction after insert on public.incoming_transactions for each row execute function public.match_incoming_transaction();

create or replace function public.confirm_order_payment(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
begin
  if not exists (
    select 1 from public.profiles where id = auth.uid() and role = 'proprietaire'
  ) then raise exception 'Accès réservé au propriétaire'; end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or v_order.status <> 'en_attente' or v_order.expires_at <= now() then
    raise exception 'Cette commande n’est plus payable';
  end if;
  update public.orders set status = 'paye' where id = p_order_id;
  update public.tickets set status = 'valide' where order_id = p_order_id;
  update public.ticket_lots l
  set held = l.held - sold.amount, sold = l.sold + sold.amount
  from (
    select lot_id, count(*)::integer as amount
    from public.order_lines where order_id = p_order_id group by lot_id
  ) sold
  where l.id = sold.lot_id;
end;
$$;

drop function if exists public.scan_ticket(uuid, text, text, uuid);
create function public.scan_ticket(
  p_event_id uuid, p_gate text, p_code text default null, p_ticket_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket public.tickets%rowtype;
  v_role text;
  v_result text;
  v_event_status text;
  v_event public.events%rowtype;
  v_lot text;
  v_category text;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if v_role is null or not (
    v_role = 'proprietaire'
    or (v_role = 'personnel' and exists (select 1 from public.staff_assignments
               where event_id = p_event_id and user_id = auth.uid()
                 and (active_until is null or active_until > now()))
    )
  ) then raise exception 'Vous n’êtes pas affecté à cet événement'; end if;

  select * into v_ticket from public.tickets
  where (p_ticket_id is not null and id = p_ticket_id)
     or (p_ticket_id is null and p_code is not null and code = p_code)
  limit 1;
  if not found then return jsonb_build_object('result', 'faux'); end if;
  if v_ticket.event_id <> p_event_id then
    return jsonb_build_object('result', 'autre_evenement', 'other_event', 'un autre événement');
  end if;
  select * into v_event from public.events where id = p_event_id;
  v_event_status := v_event.status;
  if v_event.ends_at is not null and now() > v_event.ends_at then
    raise exception 'Cette activité est terminée';
  end if;
  v_result := case v_ticket.status
    when 'valide' then 'valide'
    when 'utilise' then 'deja_utilise'
    when 'en_attente_confirmation' then 'en_attente'
    else 'annule'
  end;
  if v_event_status = 'annule' then v_result := 'annule'; end if;
  select l.name, c.name into v_lot, v_category
  from public.ticket_lots l
  join public.ticket_categories c on c.id = l.category_id
  where l.id = v_ticket.lot_id;
  return jsonb_build_object(
    'result', v_result, 'ticket_id', v_ticket.id, 'holder_name', v_ticket.holder_name,
    'photo_path', v_ticket.photo_path, 'holder_phone', v_ticket.holder_phone,
    'holder_email', v_ticket.holder_email, 'event_title', v_event.title,
    'used_at', v_ticket.scanned_at,
    'photo_required', v_event.require_ticket_photo,
    'lot', v_lot, 'category', v_category,
    'staff', coalesce((select jsonb_agg(jsonb_build_object(
      'name', p.full_name, 'email', u.email, 'phone', p.phone, 'gate', s.gate
    ) order by p.full_name)
    from public.staff_assignments s
    join public.profiles p on p.id = s.user_id
    join auth.users u on u.id = s.user_id
    where s.event_id = p_event_id
      and (s.active_until is null or s.active_until > now())), '[]'::jsonb)
  );
end;
$$;

drop function if exists public.confirm_entry(uuid, text);
create function public.confirm_entry(p_ticket_id uuid, p_gate text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket public.tickets%rowtype;
begin
  select * into v_ticket from public.tickets where id = p_ticket_id for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'Billet introuvable'); end if;
  if not (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'proprietaire')
    or (exists (select 1 from public.profiles where id = auth.uid() and role = 'personnel')
      and exists (select 1 from public.staff_assignments
               where event_id = v_ticket.event_id and user_id = auth.uid()
                 and (active_until is null or active_until > now()))
    )
  ) then raise exception 'Vous n’êtes pas affecté à cet événement'; end if;
  if v_ticket.status <> 'valide' then
    return jsonb_build_object('ok', false, 'message', 'Le billet n’est plus valide');
  end if;
  if exists (select 1 from public.events where id = v_ticket.event_id and status = 'annule') then
    return jsonb_build_object('ok', false, 'message', 'Cet événement a été annulé');
  end if;
  if exists (select 1 from public.events where id = v_ticket.event_id and ends_at is not null and now() > ends_at) then
    return jsonb_build_object('ok', false, 'message', 'Cette activité est terminée');
  end if;
  update public.tickets
  set status = 'utilise', scanned_at = now(), scanned_by = auth.uid(),
      scanned_gate = left(coalesce(nullif(trim(p_gate), ''), 'Porte 1'), 30)
  where id = p_ticket_id;
  return jsonb_build_object('ok', true);
end;
$$;

drop function if exists public.entry_counts(uuid);
create function public.entry_counts(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'proprietaire')
    or (exists (select 1 from public.profiles where id = auth.uid() and role = 'personnel')
      and exists (select 1 from public.staff_assignments
               where event_id = p_event_id and user_id = auth.uid()
                 and (active_until is null or active_until > now()))
    )
  ) then raise exception 'Vous n’êtes pas affecté à cet événement'; end if;
  return jsonb_build_object(
    'total', (select count(*) from public.tickets where event_id = p_event_id and status in ('valide', 'utilise')),
    'entered', (select count(*) from public.tickets where event_id = p_event_id and status = 'utilise')
  );
end;
$$;

create or replace function public.search_tickets(p_event_id uuid, p_query text)
returns table (id uuid, holder_name text, lot text, phone_end text, status text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'proprietaire')
    or (exists (select 1 from public.profiles where id = auth.uid() and role = 'personnel')
      and exists (select 1 from public.staff_assignments
               where event_id = p_event_id and user_id = auth.uid()
                 and (active_until is null or active_until > now()))
    )
  ) then raise exception 'Vous n’êtes pas affecté à cet événement'; end if;
  if length(trim(coalesce(p_query, ''))) < 3 then return; end if;
  return query
    select t.id, t.holder_name, l.name,
      case when t.holder_phone is null then null else right(regexp_replace(t.holder_phone, '\D', '', 'g'), 4) end,
      t.status
    from public.tickets t
    join public.ticket_lots l on l.id = t.lot_id
    where t.event_id = p_event_id
      and (t.holder_name ilike '%' || trim(p_query) || '%'
        or t.holder_phone ilike '%' || trim(p_query) || '%')
    order by t.holder_name limit 20;
end;
$$;

create or replace function public.report_not_holder(p_ticket_id uuid, p_present_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket public.tickets%rowtype;
  v_incident_id uuid;
begin
  select * into v_ticket from public.tickets where id = p_ticket_id for update;
  if not found or v_ticket.status <> 'valide' then
    raise exception 'Ce billet ne peut pas être signalé';
  end if;
  if not (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'proprietaire')
    or (exists (select 1 from public.profiles where id = auth.uid() and role = 'personnel')
      and exists (select 1 from public.staff_assignments
                  where event_id = v_ticket.event_id and user_id = auth.uid()
                    and (active_until is null or active_until > now())))
  ) then raise exception 'Vous n’êtes pas affecté à cet événement'; end if;
  if length(trim(coalesce(p_present_name, ''))) not between 1 and 80 then
    raise exception 'Le nom de la personne présente est invalide';
  end if;
  insert into public.incidents (ticket_id, event_id, reported_by, present_person_name)
  values (v_ticket.id, v_ticket.event_id, auth.uid(), trim(p_present_name))
  returning id into v_incident_id;
  update public.tickets set status = 'en_attente_confirmation' where id = v_ticket.id;
  return v_incident_id;
end;
$$;

create or replace function public.list_open_incidents()
returns table (
  id uuid, status text, present_person_name text, created_at timestamptz,
  event_title text, holder_name text, holder_phone text, buyer_name text,
  buyer_phone text, reported_by_name text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'proprietaire') then
    raise exception 'Accès réservé au propriétaire';
  end if;
  return query
    select i.id, i.status, i.present_person_name, i.created_at, e.title,
      t.holder_name, t.holder_phone, buyer.full_name, t.holder_phone, reporter.full_name
    from public.incidents i
    join public.events e on e.id = i.event_id
    join public.tickets t on t.id = i.ticket_id
    join public.orders o on o.id = t.order_id
    join public.profiles buyer on buyer.id = o.user_id
    join public.profiles reporter on reporter.id = i.reported_by
    where i.status = 'ouvert'
    order by i.created_at;
end;
$$;

create or replace function public.decide_incident(
  p_incident_id uuid, p_decision text, p_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_incident public.incidents%rowtype;
begin
  if p_decision is null or p_decision not in ('autorise', 'refuse') then
    raise exception 'Décision invalide';
  end if;
  select * into v_incident from public.incidents where id = p_incident_id for update;
  if not found or v_incident.status <> 'ouvert' then
    raise exception 'Ce signalement a déjà été traité';
  end if;
  if not (
    exists (select 1 from public.profiles where id = auth.uid() and role = 'proprietaire')
    or exists (
      select 1 from public.events e join public.profiles p on p.id = auth.uid()
      where e.id = v_incident.event_id and e.created_by = auth.uid()
        and p.role = 'organisateur' and (p.role_expires_at is null or p.role_expires_at > now())
    )
  ) then raise exception 'Vous ne pouvez pas traiter ce signalement'; end if;
  update public.incidents
  set status = p_decision, resolved_by = auth.uid(), resolved_at = now(),
      decision_note = nullif(trim(coalesce(p_note, '')), '')
  where id = p_incident_id;
  update public.tickets
  set status = case p_decision when 'autorise' then 'valide' else 'bloque' end
  where id = v_incident.ticket_id and status = 'en_attente_confirmation';
end;
$$;

revoke all on function public.expire_pending_orders() from public, anon, authenticated;
revoke all on function public.settle_payment(uuid) from public, anon, authenticated;
revoke all on function public.start_payment(uuid, text, text) from public, anon;
revoke all on function public.submit_transfer_code(uuid, text, text, text) from public, anon;
revoke all on function public.simulate_payment_success(uuid) from public, anon;
revoke all on function public.approve_code_payment(uuid) from public, anon;
revoke all on function public.reject_code_payment(uuid) from public, anon;
revoke all on function public.match_incoming_transaction() from public, anon, authenticated;
revoke all on function public.create_order(uuid, jsonb) from public, anon;
revoke all on function public.confirm_order_payment(uuid) from public, anon;
revoke all on function public.scan_ticket(uuid, text, text, uuid) from public, anon;
revoke all on function public.confirm_entry(uuid, text) from public, anon;
revoke all on function public.entry_counts(uuid) from public, anon;
revoke all on function public.search_tickets(uuid, text) from public, anon;
revoke all on function public.report_not_holder(uuid, text) from public, anon;
revoke all on function public.list_open_incidents() from public, anon;
revoke all on function public.decide_incident(uuid, text, text) from public, anon;
revoke all on function public.assign_staff(text, uuid, text) from public, anon;
revoke all on function public.list_staff(uuid) from public, anon;
revoke all on function public.remove_staff(uuid) from public, anon;
grant execute on function public.create_order(uuid, jsonb),
  public.start_payment(uuid, text, text), public.submit_transfer_code(uuid, text, text, text),
  public.simulate_payment_success(uuid), public.approve_code_payment(uuid), public.reject_code_payment(uuid),
  public.confirm_order_payment(uuid), public.scan_ticket(uuid, text, text, uuid),
  public.confirm_entry(uuid, text), public.entry_counts(uuid),
  public.search_tickets(uuid, text), public.report_not_holder(uuid, text),
  public.list_open_incidents(), public.decide_incident(uuid, text, text),
  public.assign_staff(text, uuid, text), public.list_staff(uuid),
  public.remove_staff(uuid) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ticket-photos', 'ticket-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

create or replace function public.can_read_ticket_photo(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.tickets t
    join public.events e on e.id = t.event_id
    where t.photo_path = p_name
      and (
        t.owner_id = auth.uid()
        or exists (select 1 from public.profiles p
                   where p.id = auth.uid() and p.role = 'organisateur'
                     and e.created_by = auth.uid()
                     and (p.role_expires_at is null or p.role_expires_at > now()))
        or exists (select 1 from public.profiles p
                   where p.id = auth.uid() and p.role = 'proprietaire')
        or (exists (select 1 from public.profiles p
                    where p.id = auth.uid() and p.role = 'personnel')
            and exists (select 1 from public.staff_assignments s
                        where s.event_id = t.event_id and s.user_id = auth.uid()))
      )
  );
$$;

revoke all on function public.can_read_ticket_photo(text) from public, anon;
grant execute on function public.can_read_ticket_photo(text) to authenticated;

create or replace function public.can_delete_unlinked_ticket_photo(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (storage.foldername(p_name))[1] = auth.uid()::text
    and not exists (select 1 from public.tickets where photo_path = p_name);
$$;

revoke all on function public.can_delete_unlinked_ticket_photo(text) from public, anon;
grant execute on function public.can_delete_unlinked_ticket_photo(text) to authenticated;

drop policy if exists "Ticket buyers can upload their own photos" on storage.objects;
create policy "Ticket buyers can upload their own photos"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'ticket-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "Ticket owners and assigned staff can read photos" on storage.objects;
create policy "Ticket owners and assigned staff can read photos"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'ticket-photos'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or public.can_read_ticket_photo(name)
    )
  );

drop policy if exists "Ticket buyers can remove their own photos" on storage.objects;
create policy "Ticket buyers can remove their own photos"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'ticket-photos'
    and public.can_delete_unlinked_ticket_photo(name)
  );

-- Après avoir créé le compte du propriétaire et confirmé son email, exécuter
-- une seule fois dans le SQL Editor en remplaçant l'adresse :
-- update public.profiles p
-- set role = 'proprietaire'
-- from auth.users u
-- where p.id = u.id and lower(u.email) = lower('votre-email@example.com');
--
-- Après confirmation du compte d'un organisateur, le propriétaire peut lui
-- accorder un accès temporaire depuis le SQL Editor en remplaçant l'adresse
-- et la durée (exemple : 90 jours) :
-- update public.profiles p
-- set role = 'organisateur', role_expires_at = now() + interval '90 days'
-- from auth.users u
-- where p.id = u.id and lower(u.email) = lower('organisateur@example.com');
--
-- Pour les essais du personnel, le propriétaire peut promouvoir un compte
-- déjà créé et confirmé, en remplaçant l'adresse :
-- update public.profiles p
-- set role = 'personnel'
-- from auth.users u
-- where p.id = u.id and lower(u.email) = lower('personnel@example.com');

