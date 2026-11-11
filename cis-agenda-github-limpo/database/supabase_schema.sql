begin;

create schema if not exists private;

create table if not exists public.specialties (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code in ('fisioterapia', 'nutricao', 'enfermagem')),
  name text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.specialties (code, name)
values
  ('fisioterapia', 'Fisioterapia'),
  ('nutricao', 'Nutrição'),
  ('enfermagem', 'Enfermagem')
on conflict (code) do update set name = excluded.name;

create table if not exists public.staff_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.academic_terms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  starts_on date not null,
  ends_on date not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (starts_on <= ends_on)
);

create table if not exists public.interns (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.service_shifts (
  id uuid primary key default gen_random_uuid(),
  academic_term_id uuid not null references public.academic_terms(id) on delete restrict,
  specialty_id uuid not null references public.specialties(id) on delete restrict,
  weekday smallint not null check (weekday between 0 and 6),
  case_discussion_starts_at time not null,
  service_starts_at time not null,
  service_ends_at time not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (case_discussion_starts_at < service_starts_at),
  check (service_starts_at < service_ends_at),
  unique (academic_term_id, specialty_id, weekday, service_starts_at)
);

create table if not exists public.intern_shift_assignments (
  id uuid primary key default gen_random_uuid(),
  service_shift_id uuid not null references public.service_shifts(id) on delete cascade,
  intern_id uuid not null references public.interns(id) on delete restrict,
  assigned_from date not null,
  assigned_until date,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (assigned_until is null or assigned_until >= assigned_from),
  unique (service_shift_id, intern_id, assigned_from)
);

create table if not exists public.patients (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.patient_telegram_links (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patients(id) on delete cascade,
  telegram_user_id bigint not null,
  telegram_chat_id bigint not null,
  relationship text not null default 'patient'
    check (relationship in ('patient', 'parent', 'guardian', 'responsible', 'other')),
  verified_at timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  unique (patient_id, telegram_user_id)
);

create table if not exists public.telegram_link_tokens (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patients(id) on delete cascade,
  token_hash text not null unique,
  created_by uuid references public.staff_profiles(id) on delete set null,
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.form_submissions (
  id uuid primary key default gen_random_uuid(),
  specialty_id uuid not null references public.specialties(id) on delete restrict,
  patient_id uuid references public.patients(id) on delete set null,
  source text not null default 'google_forms'
    check (source in ('google_forms', 'test_manual')),
  source_form_id text,
  source_response_id text,
  submitted_at timestamptz not null default now(),
  patient_full_name text not null,
  age_years integer check (age_years between 0 and 120),
  is_pediatric boolean not null default false,
  clinical_report text,
  raw_answers jsonb not null default '{}'::jsonb,
  processing_status text not null default 'pending'
    check (processing_status in ('pending', 'reviewed', 'linked', 'rejected')),
  reviewed_by uuid references public.staff_profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  check (source <> 'google_forms' or source_form_id is not null)
);

create unique index if not exists form_submissions_external_response_uidx
  on public.form_submissions (source_form_id, source_response_id)
  where source_form_id is not null and source_response_id is not null;

create table if not exists public.service_requests (
  id uuid primary key default gen_random_uuid(),
  form_submission_id uuid not null unique references public.form_submissions(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  specialty_id uuid not null references public.specialties(id) on delete restrict,
  status text not null default 'received'
    check (status in ('received', 'under_review', 'waiting', 'proposal_sent', 'scheduled', 'closed', 'withdrawn')),
  received_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz
);

create index if not exists service_requests_status_specialty_idx
  on public.service_requests (specialty_id, status, received_at);

create table if not exists public.waitlist_entries (
  id uuid primary key default gen_random_uuid(),
  service_request_id uuid not null unique references public.service_requests(id) on delete restrict,
  specialty_id uuid not null references public.specialties(id) on delete restrict,
  status text not null default 'waiting'
    check (status in ('waiting', 'offered', 'scheduled', 'removed')),
  priority_order integer check (priority_order is null or priority_order > 0),
  priority_decided_by_name text,
  priority_recorded_by uuid references public.staff_profiles(id) on delete set null,
  priority_defined_at timestamptz,
  entered_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (priority_order is null and priority_decided_by_name is null and priority_recorded_by is null and priority_defined_at is null)
    or
    (priority_order is not null and nullif(trim(priority_decided_by_name), '') is not null and priority_recorded_by is not null and priority_defined_at is not null)
  )
);

create index if not exists waitlist_queue_idx
  on public.waitlist_entries (specialty_id, status, priority_order, entered_at);

create table if not exists public.availability_slots (
  id uuid primary key default gen_random_uuid(),
  service_shift_id uuid not null references public.service_shifts(id) on delete restrict,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  capacity integer not null default 0 check (capacity >= 0),
  active boolean not null default true,
  created_by uuid references public.staff_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check (starts_at < ends_at),
  unique (service_shift_id, starts_at)
);

create index if not exists availability_slots_start_idx
  on public.availability_slots (starts_at, active);

create table if not exists public.proposals (
  id uuid primary key default gen_random_uuid(),
  service_request_id uuid not null references public.service_requests(id) on delete restrict,
  availability_slot_id uuid not null references public.availability_slots(id) on delete restrict,
  status text not null default 'pending'
    check (status in ('pending', 'confirmed', 'declined', 'expired', 'cancelled')),
  created_by uuid not null references public.staff_profiles(id) on delete restrict,
  sent_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '48 hours'),
  responded_at timestamptz,
  interpreted_intent text check (interpreted_intent is null or interpreted_intent in ('confirm', 'decline', 'cancel', 'question', 'unknown')),
  created_at timestamptz not null default now(),
  check (expires_at > sent_at)
);

create unique index if not exists one_pending_proposal_per_request_uidx
  on public.proposals (service_request_id)
  where status = 'pending';

create index if not exists proposals_slot_status_idx
  on public.proposals (availability_slot_id, status, expires_at);

create table if not exists public.appointments (
  id uuid primary key default gen_random_uuid(),
  service_request_id uuid not null references public.service_requests(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  availability_slot_id uuid not null references public.availability_slots(id) on delete restrict,
  proposal_id uuid unique references public.proposals(id) on delete restrict,
  appointment_kind text not null default 'initial_evaluation'
    check (appointment_kind in ('initial_evaluation', 'follow_up')),
  status text not null default 'scheduled'
    check (status in ('scheduled', 'completed', 'cancelled', 'rescheduled', 'no_show')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  treatment_plan_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (starts_at < ends_at)
);

create index if not exists appointments_patient_date_idx
  on public.appointments (patient_id, starts_at desc);
create index if not exists appointments_slot_status_idx
  on public.appointments (availability_slot_id, status);

create table if not exists public.treatment_plans (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patients(id) on delete restrict,
  service_request_id uuid not null references public.service_requests(id) on delete restrict,
  specialty_id uuid not null references public.specialties(id) on delete restrict,
  sessions_per_week smallint not null check (sessions_per_week in (1, 2)),
  status text not null default 'active'
    check (status in ('active', 'review_required', 'paused', 'completed', 'cancelled')),
  starts_on date not null,
  ends_on date,
  created_by uuid references public.staff_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on is null or ends_on >= starts_on),
  unique (service_request_id)
);

alter table public.appointments
  drop constraint if exists appointments_treatment_plan_id_fkey;
alter table public.appointments
  add constraint appointments_treatment_plan_id_fkey
  foreign key (treatment_plan_id) references public.treatment_plans(id) on delete set null;

create table if not exists public.treatment_plan_days (
  id uuid primary key default gen_random_uuid(),
  treatment_plan_id uuid not null references public.treatment_plans(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  starts_at time not null,
  ends_at time not null,
  active boolean not null default true,
  check (starts_at < ends_at),
  unique (treatment_plan_id, weekday)
);

create table if not exists public.attendance_records (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null unique references public.appointments(id) on delete restrict,
  status text not null
    check (status in ('present', 'absence_without_notice', 'absence_with_notice', 'cancelled_with_notice', 'rescheduled')),
  justification text,
  notice_at timestamptz,
  recorded_via text not null default 'team'
    check (recorded_via in ('team', 'telegram', 'system')),
  recorded_by uuid references public.staff_profiles(id) on delete set null,
  recorded_at timestamptz not null default now(),
  check (
    status not in ('absence_with_notice', 'cancelled_with_notice', 'rescheduled')
    or nullif(trim(justification), '') is not null
  )
);

create table if not exists public.bot_intent_events (
  id uuid primary key default gen_random_uuid(),
  telegram_user_id bigint,
  patient_id uuid references public.patients(id) on delete set null,
  proposal_id uuid references public.proposals(id) on delete set null,
  intent text not null check (intent in ('confirm', 'decline', 'cancel', 'question', 'unknown')),
  result text not null default 'manual_review'
    check (result in ('accepted', 'rejected', 'manual_review', 'no_action')),
  model_provider text not null default 'openrouter',
  model_id text,
  created_at timestamptz not null default now()
);

create table if not exists public.system_settings (
  setting_key text primary key,
  setting_value jsonb not null,
  description text not null,
  updated_at timestamptz not null default now()
);

insert into public.system_settings (setting_key, setting_value, description)
values
  ('proposal_expiration_hours', '48'::jsonb, 'Prazo em horas para confirmar uma proposta de vaga.'),
  ('unexcused_absences_limit', '3'::jsonb, 'Quantidade acumulada de faltas sem aviso para gerar alerta de revisão humana.')
on conflict (setting_key) do nothing;

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_type text not null check (actor_type in ('staff', 'telegram', 'backend', 'system')),
  actor_reference text,
  entity_type text not null,
  entity_id uuid,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists audit_logs_entity_idx
  on public.audit_logs (entity_type, entity_id, created_at desc);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'staff_profiles', 'academic_terms', 'interns', 'service_shifts',
    'patients', 'service_requests', 'waitlist_entries', 'appointments',
    'treatment_plans'
  ] LOOP
    EXECUTE format('drop trigger if exists set_updated_at on public.%I', table_name);
    EXECUTE format(
      'create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()',
      table_name
    );
  END LOOP;
END;
$$;

create or replace function public.set_slot_capacity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_shift public.service_shifts%rowtype;
  v_slot_local_start timestamp;
  v_slot_local_end timestamp;
  v_count integer;
begin
  select * into v_shift
  from public.service_shifts
  where id = new.service_shift_id and active = true;

  if not found then
    raise exception 'Turno inexistente ou inativo.';
  end if;

  v_slot_local_start := new.starts_at at time zone 'America/Bahia';
  v_slot_local_end := new.ends_at at time zone 'America/Bahia';

  if extract(dow from v_slot_local_start)::integer <> v_shift.weekday then
    raise exception 'A data da vaga não corresponde ao dia da semana configurado para o turno.';
  end if;

  if v_slot_local_start::time < v_shift.service_starts_at
     or v_slot_local_end::time > v_shift.service_ends_at then
    raise exception 'O horário da vaga está fora do período de atendimento do turno.';
  end if;

  select count(*)::integer into v_count
  from public.intern_shift_assignments a
  join public.interns i on i.id = a.intern_id and i.active = true
  where a.service_shift_id = new.service_shift_id
    and a.active = true
    and a.assigned_from <= v_slot_local_start::date
    and (a.assigned_until is null or a.assigned_until >= v_slot_local_start::date);

  new.capacity := coalesce(v_count, 0);
  return new;
end;
$$;

drop trigger if exists set_slot_capacity_before_write on public.availability_slots;
create trigger set_slot_capacity_before_write
before insert or update
on public.availability_slots
for each row execute function public.set_slot_capacity();

create or replace function private.refresh_future_slot_capacities(p_service_shift_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot record;
  v_new_capacity integer;
  v_occupied integer;
  v_local_date date;
begin
  for v_slot in
    select id, starts_at
    from public.availability_slots
    where service_shift_id = p_service_shift_id
      and starts_at > now()
    for update
  loop
    v_local_date := (v_slot.starts_at at time zone 'America/Bahia')::date;

    select count(*)::integer into v_new_capacity
    from public.intern_shift_assignments a
    join public.interns i on i.id = a.intern_id and i.active = true
    where a.service_shift_id = p_service_shift_id
      and a.active = true
      and a.assigned_from <= v_local_date
      and (a.assigned_until is null or a.assigned_until >= v_local_date);

    select
      (select count(*) from public.proposals p
       where p.availability_slot_id = v_slot.id
         and p.status = 'pending' and p.expires_at > now())
      +
      (select count(*) from public.appointments ap
       where ap.availability_slot_id = v_slot.id and ap.status = 'scheduled')
    into v_occupied;

    if coalesce(v_new_capacity, 0) < coalesce(v_occupied, 0) then
      raise exception 'Não é possível reduzir a capacidade: a vaga % já possui % reservas/agendamentos.', v_slot.id, v_occupied;
    end if;

    update public.availability_slots
    set capacity = coalesce(v_new_capacity, 0)
    where id = v_slot.id;
  end loop;
end;
$$;

create or replace function public.on_intern_assignment_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform private.refresh_future_slot_capacities(old.service_shift_id);
    return old;
  elsif tg_op = 'UPDATE' then
    if old.service_shift_id is distinct from new.service_shift_id then
      perform private.refresh_future_slot_capacities(old.service_shift_id);
    end if;
    perform private.refresh_future_slot_capacities(new.service_shift_id);
    return new;
  else
    perform private.refresh_future_slot_capacities(new.service_shift_id);
    return new;
  end if;
end;
$$;

drop trigger if exists refresh_slots_after_intern_assignment on public.intern_shift_assignments;
create trigger refresh_slots_after_intern_assignment
after insert or update or delete on public.intern_shift_assignments
for each row execute function public.on_intern_assignment_change();

create or replace function private.refresh_slots_after_intern_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shift_id uuid;
begin
  if old.active is not distinct from new.active then
    return new;
  end if;
  for v_shift_id in
    select distinct service_shift_id
    from public.intern_shift_assignments
    where intern_id = new.id
  loop
    perform private.refresh_future_slot_capacities(v_shift_id);
  end loop;
  return new;
end;
$$;

drop trigger if exists refresh_slots_after_intern_status_change on public.interns;
create trigger refresh_slots_after_intern_status_change
after update of active on public.interns
for each row execute function private.refresh_slots_after_intern_status_change();

create or replace function public.flag_treatment_after_absence()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan_id uuid;
  v_limit integer;
  v_absences integer;
begin
  if new.status <> 'absence_without_notice' then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.status = 'absence_without_notice' then
    return new;
  end if;

  select treatment_plan_id into v_plan_id
  from public.appointments
  where id = new.appointment_id;

  if v_plan_id is null then
    return new;
  end if;

  select coalesce((setting_value #>> '{}')::integer, 3)
  into v_limit
  from public.system_settings
  where setting_key = 'unexcused_absences_limit';
  v_limit := coalesce(v_limit, 3);

  select count(*)::integer into v_absences
  from public.attendance_records ar
  join public.appointments ap on ap.id = ar.appointment_id
  where ap.treatment_plan_id = v_plan_id
    and ar.status = 'absence_without_notice';

  if v_absences >= v_limit then
    update public.treatment_plans
    set status = 'review_required'
    where id = v_plan_id and status = 'active';

    insert into public.audit_logs (actor_type, entity_type, entity_id, action, details)
    values ('system', 'treatment_plan', v_plan_id, 'absence_threshold_reached',
      jsonb_build_object('unexcused_absences', v_absences, 'configured_limit', v_limit, 'requires_human_review', true));
  end if;

  return new;
end;
$$;

drop trigger if exists flag_treatment_after_absence on public.attendance_records;
create trigger flag_treatment_after_absence
after insert or update of status on public.attendance_records
for each row execute function public.flag_treatment_after_absence();

create or replace function public.consume_telegram_link_token(
  p_token_hash text,
  p_telegram_user_id bigint,
  p_telegram_chat_id bigint,
  p_relationship text default 'patient'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token public.telegram_link_tokens%rowtype;
begin
  if p_relationship not in ('patient', 'parent', 'guardian', 'responsible', 'other') then
    raise exception 'Tipo de vínculo inválido.';
  end if;

  select * into v_token
  from public.telegram_link_tokens
  where token_hash = p_token_hash
    and used_at is null
    and expires_at > now()
  for update;

  if not found then
    raise exception 'Código de vinculação inválido, expirado ou já utilizado.';
  end if;

  update public.telegram_link_tokens
  set used_at = now()
  where id = v_token.id;

  insert into public.patient_telegram_links (
    patient_id, telegram_user_id, telegram_chat_id, relationship, verified_at, revoked_at
  ) values (
    v_token.patient_id, p_telegram_user_id, p_telegram_chat_id, p_relationship, now(), null
  )
  on conflict (patient_id, telegram_user_id)
  do update set
    telegram_chat_id = excluded.telegram_chat_id,
    relationship = excluded.relationship,
    verified_at = now(),
    revoked_at = null;

  insert into public.audit_logs (actor_type, actor_reference, entity_type, entity_id, action, details)
  values ('telegram', p_telegram_user_id::text, 'patient', v_token.patient_id, 'telegram_account_linked',
          jsonb_build_object('relationship', p_relationship));

  return v_token.patient_id;
end;
$$;

create or replace function public.create_proposal(
  p_service_request_id uuid,
  p_availability_slot_id uuid,
  p_created_by uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.service_requests%rowtype;
  v_slot public.availability_slots%rowtype;
  v_slot_specialty uuid;
  v_occupied integer;
  v_expiration_hours integer;
  v_proposal_id uuid;
begin
  if not exists (select 1 from public.staff_profiles sp where sp.id = p_created_by and sp.active = true) then
    raise exception 'Usuário da equipe inválido ou inativo.';
  end if;

  select * into v_request
  from public.service_requests
  where id = p_service_request_id
  for update;
  if not found then raise exception 'Solicitação não encontrada.'; end if;
  if v_request.status not in ('received', 'under_review', 'waiting') then
    raise exception 'A solicitação não está apta a receber uma proposta.';
  end if;

  if exists (select 1 from public.proposals p where p.service_request_id = p_service_request_id and p.status = 'pending') then
    raise exception 'Já existe uma proposta pendente para esta solicitação.';
  end if;

  select * into v_slot
  from public.availability_slots
  where id = p_availability_slot_id and active = true
  for update;
  if not found then raise exception 'Vaga não encontrada ou inativa.'; end if;
  if v_slot.starts_at <= now() then raise exception 'Não é possível propor uma vaga passada.'; end if;

  select specialty_id into v_slot_specialty
  from public.service_shifts
  where id = v_slot.service_shift_id and active = true;
  if v_slot_specialty is distinct from v_request.specialty_id then
    raise exception 'A especialidade da vaga não corresponde à solicitação.';
  end if;

  select
    (select count(*) from public.proposals p
     where p.availability_slot_id = v_slot.id
       and p.status = 'pending' and p.expires_at > now())
    +
    (select count(*) from public.appointments ap
     where ap.availability_slot_id = v_slot.id and ap.status = 'scheduled')
  into v_occupied;

  if coalesce(v_occupied, 0) >= v_slot.capacity then
    raise exception 'Não há capacidade disponível neste horário.';
  end if;

  select coalesce((setting_value #>> '{}')::integer, 48)
  into v_expiration_hours
  from public.system_settings
  where setting_key = 'proposal_expiration_hours';
  v_expiration_hours := coalesce(v_expiration_hours, 48);
  if v_expiration_hours < 1 or v_expiration_hours > 168 then
    raise exception 'Configuração de expiração de proposta inválida.';
  end if;

  insert into public.proposals (service_request_id, availability_slot_id, created_by, expires_at)
  values (p_service_request_id, p_availability_slot_id, p_created_by,
          now() + make_interval(hours => v_expiration_hours))
  returning id into v_proposal_id;

  update public.service_requests set status = 'proposal_sent' where id = p_service_request_id;
  update public.waitlist_entries set status = 'offered', updated_at = now()
  where service_request_id = p_service_request_id and status = 'waiting';

  insert into public.audit_logs (actor_type, actor_reference, entity_type, entity_id, action, details)
  values ('staff', p_created_by::text, 'proposal', v_proposal_id, 'proposal_created',
          jsonb_build_object('service_request_id', p_service_request_id, 'availability_slot_id', p_availability_slot_id, 'expires_at', now() + make_interval(hours => v_expiration_hours)));

  return v_proposal_id;
end;
$$;

create or replace function public.confirm_proposal(
  p_proposal_id uuid,
  p_telegram_user_id bigint
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request_id uuid;
  v_patient_id uuid;
  v_slot_id uuid;
  v_status text;
  v_expires_at timestamptz;
  v_starts_at timestamptz;
  v_ends_at timestamptz;
  v_appointment_id uuid;
begin
  select p.service_request_id, r.patient_id, p.availability_slot_id, p.status, p.expires_at
  into v_request_id, v_patient_id, v_slot_id, v_status, v_expires_at
  from public.proposals p
  join public.service_requests r on r.id = p.service_request_id
  where p.id = p_proposal_id
  for update of p;
  if not found then raise exception 'Proposta não encontrada.'; end if;

  if not exists (
    select 1 from public.patient_telegram_links l
    where l.patient_id = v_patient_id
      and l.telegram_user_id = p_telegram_user_id
      and l.revoked_at is null
  ) then
    raise exception 'Esta conta do Telegram não está vinculada ao paciente desta proposta.';
  end if;

  if v_status <> 'pending' then raise exception 'Esta proposta não está pendente.'; end if;
  if v_expires_at <= now() then raise exception 'O prazo de confirmação da proposta expirou.'; end if;

  select starts_at, ends_at into v_starts_at, v_ends_at
  from public.availability_slots
  where id = v_slot_id and active = true
  for update;
  if not found then raise exception 'A vaga não está mais disponível.'; end if;
  if v_starts_at <= now() then raise exception 'O horário da proposta já passou.'; end if;

  update public.proposals
  set status = 'confirmed', responded_at = now(), interpreted_intent = 'confirm'
  where id = p_proposal_id;

  insert into public.appointments (
    service_request_id, patient_id, availability_slot_id, proposal_id,
    appointment_kind, status, starts_at, ends_at
  ) values (
    v_request_id, v_patient_id, v_slot_id, p_proposal_id,
    'initial_evaluation', 'scheduled', v_starts_at, v_ends_at
  ) returning id into v_appointment_id;

  update public.service_requests set status = 'scheduled' where id = v_request_id;
  update public.waitlist_entries set status = 'scheduled', updated_at = now()
  where service_request_id = v_request_id;

  insert into public.audit_logs (actor_type, actor_reference, entity_type, entity_id, action, details)
  values ('telegram', p_telegram_user_id::text, 'appointment', v_appointment_id, 'proposal_confirmed',
          jsonb_build_object('proposal_id', p_proposal_id, 'service_request_id', v_request_id));

  return v_appointment_id;
end;
$$;

create or replace function public.decline_proposal(
  p_proposal_id uuid,
  p_telegram_user_id bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request_id uuid;
  v_patient_id uuid;
  v_status text;
  v_expires_at timestamptz;
begin
  select p.service_request_id, r.patient_id, p.status, p.expires_at
  into v_request_id, v_patient_id, v_status, v_expires_at
  from public.proposals p
  join public.service_requests r on r.id = p.service_request_id
  where p.id = p_proposal_id
  for update of p;
  if not found then raise exception 'Proposta não encontrada.'; end if;

  if not exists (
    select 1 from public.patient_telegram_links l
    where l.patient_id = v_patient_id
      and l.telegram_user_id = p_telegram_user_id
      and l.revoked_at is null
  ) then
    raise exception 'Esta conta do Telegram não está vinculada ao paciente desta proposta.';
  end if;
  if v_status <> 'pending' then raise exception 'Esta proposta não está pendente.'; end if;
  if v_expires_at <= now() then raise exception 'O prazo de resposta da proposta expirou.'; end if;

  update public.proposals
  set status = 'declined', responded_at = now(), interpreted_intent = 'decline'
  where id = p_proposal_id;
  update public.service_requests set status = 'waiting' where id = v_request_id;
  update public.waitlist_entries set status = 'waiting', updated_at = now()
  where service_request_id = v_request_id;

  insert into public.audit_logs (actor_type, actor_reference, entity_type, entity_id, action, details)
  values ('telegram', p_telegram_user_id::text, 'proposal', p_proposal_id, 'proposal_declined',
          jsonb_build_object('service_request_id', v_request_id));
end;
$$;

create or replace function public.expire_pending_proposals()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  with expired as (
    update public.proposals
    set status = 'expired', responded_at = now()
    where status = 'pending' and expires_at <= now()
    returning id, service_request_id
  ), requests_updated as (
    update public.service_requests r
    set status = 'waiting', updated_at = now()
    from expired e
    where r.id = e.service_request_id and r.status = 'proposal_sent'
    returning r.id
  ), waitlist_updated as (
    update public.waitlist_entries w
    set status = 'waiting', updated_at = now()
    from expired e
    where w.service_request_id = e.service_request_id and w.status = 'offered'
    returning w.id
  ), audit_inserted as (
    insert into public.audit_logs (actor_type, entity_type, entity_id, action, details)
    select 'system', 'proposal', e.id, 'proposal_expired', jsonb_build_object('service_request_id', e.service_request_id)
    from expired e
    returning id
  )
  select count(*)::integer into v_count from expired;

  return coalesce(v_count, 0);
end;
$$;

create or replace function public.cancel_appointment(
  p_appointment_id uuid,
  p_telegram_user_id bigint,
  p_justification text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_patient_id uuid;
  v_status text;
begin
  if nullif(trim(p_justification), '') is null then
    raise exception 'É necessário informar uma justificativa para o cancelamento.';
  end if;

  select patient_id, status into v_patient_id, v_status
  from public.appointments
  where id = p_appointment_id
  for update;
  if not found then raise exception 'Agendamento não encontrado.'; end if;

  if not exists (
    select 1 from public.patient_telegram_links l
    where l.patient_id = v_patient_id
      and l.telegram_user_id = p_telegram_user_id
      and l.revoked_at is null
  ) then
    raise exception 'Esta conta do Telegram não está vinculada ao paciente deste agendamento.';
  end if;
  if v_status <> 'scheduled' then raise exception 'Este agendamento não está ativo para cancelamento.'; end if;

  update public.appointments set status = 'cancelled', updated_at = now()
  where id = p_appointment_id;

  insert into public.attendance_records (
    appointment_id, status, justification, notice_at, recorded_via
  ) values (
    p_appointment_id, 'cancelled_with_notice', trim(p_justification), now(), 'telegram'
  );

  insert into public.audit_logs (actor_type, actor_reference, entity_type, entity_id, action, details)
  values ('telegram', p_telegram_user_id::text, 'appointment', p_appointment_id, 'appointment_cancelled',
          jsonb_build_object('justification_provided', true));
end;
$$;

create or replace view public.patient_absence_summary
with (security_invoker = true)
as
select
  ap.patient_id,
  ap.treatment_plan_id,
  count(*) filter (where ar.status = 'absence_without_notice')::integer as unexcused_absences,
  coalesce((select (ss.setting_value #>> '{}')::integer
            from public.system_settings ss
            where ss.setting_key = 'unexcused_absences_limit'), 3) as configured_limit,
  (count(*) filter (where ar.status = 'absence_without_notice') >=
    coalesce((select (ss.setting_value #>> '{}')::integer
              from public.system_settings ss
              where ss.setting_key = 'unexcused_absences_limit'), 3)) as requires_human_review
from public.appointments ap
left join public.attendance_records ar on ar.appointment_id = ap.id
group by ap.patient_id, ap.treatment_plan_id;

comment on column public.form_submissions.clinical_report is
  'Dado sensível informado no formulário. Acesso restrito à equipe autorizada. Nunca enviar a modelos externos de IA.';
comment on column public.form_submissions.raw_answers is
  'Respostas originais do formulário. Pode conter dados pessoais/sensíveis; não enviar a serviços externos de IA.';
comment on column public.waitlist_entries.priority_decided_by_name is
  'Nome do professor/preceptor que efetivamente definiu a prioridade; a IA e o sistema não decidem prioridade.';
comment on column public.waitlist_entries.priority_recorded_by is
  'Usuário da equipe que registrou no sistema a decisão humana de prioridade.';
comment on column public.availability_slots.capacity is
  'Calculada automaticamente pela quantidade de estagiários ativos atribuídos ao turno na data da vaga.';
comment on table public.audit_logs is
  'Auditoria de operações. Não armazenar texto bruto de mensagens, sintomas, CPF, telefone ou outros dados sensíveis.';

create or replace function private.is_cis_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.staff_profiles sp
    where sp.id = (select auth.uid())
      and sp.active = true
  );
$$;

revoke all on function private.is_cis_staff() from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.is_cis_staff() to authenticated;
revoke all on function private.refresh_future_slot_capacities(uuid) from public, anon, authenticated;
revoke all on function private.refresh_slots_after_intern_status_change() from public, anon, authenticated;

DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'specialties', 'staff_profiles', 'academic_terms', 'interns', 'service_shifts',
    'intern_shift_assignments', 'patients', 'patient_telegram_links', 'telegram_link_tokens',
    'form_submissions', 'service_requests', 'waitlist_entries', 'availability_slots',
    'proposals', 'appointments', 'treatment_plans', 'treatment_plan_days',
    'attendance_records', 'bot_intent_events', 'system_settings', 'audit_logs'
  ] LOOP
    EXECUTE format('alter table public.%I enable row level security', table_name);
    EXECUTE format('revoke all on table public.%I from anon', table_name);
    EXECUTE format('grant all on table public.%I to service_role', table_name);
  END LOOP;
END;
$$;

revoke all on table public.staff_profiles from authenticated;
grant select on table public.staff_profiles to authenticated;
drop policy if exists staff_profiles_read_team on public.staff_profiles;
create policy staff_profiles_read_team
on public.staff_profiles for select to authenticated
using ((select private.is_cis_staff()));

DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'academic_terms', 'interns', 'service_shifts', 'intern_shift_assignments',
    'patients', 'form_submissions', 'service_requests', 'waitlist_entries',
    'availability_slots', 'treatment_plans', 'treatment_plan_days', 'attendance_records'
  ] LOOP
    EXECUTE format('grant select, insert, update, delete on table public.%I to authenticated', table_name);
    EXECUTE format('drop policy if exists team_manage on public.%I', table_name);
    EXECUTE format(
      'create policy team_manage on public.%I for all to authenticated using ((select private.is_cis_staff())) with check ((select private.is_cis_staff()))',
      table_name
    );
  END LOOP;
END;
$$;

DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'specialties', 'patient_telegram_links', 'proposals', 'appointments',
    'bot_intent_events', 'system_settings', 'audit_logs'
  ] LOOP
    EXECUTE format('grant select on table public.%I to authenticated', table_name);
    EXECUTE format('drop policy if exists team_read on public.%I', table_name);
    EXECUTE format(
      'create policy team_read on public.%I for select to authenticated using ((select private.is_cis_staff()))',
      table_name
    );
  END LOOP;
END;
$$;

revoke all on table public.telegram_link_tokens from anon, authenticated;

revoke all on function public.consume_telegram_link_token(text, bigint, bigint, text) from public, anon, authenticated;
revoke all on function public.create_proposal(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.confirm_proposal(uuid, bigint) from public, anon, authenticated;
revoke all on function public.decline_proposal(uuid, bigint) from public, anon, authenticated;
revoke all on function public.expire_pending_proposals() from public, anon, authenticated;
revoke all on function public.cancel_appointment(uuid, bigint, text) from public, anon, authenticated;
grant execute on function public.consume_telegram_link_token(text, bigint, bigint, text) to service_role;
grant execute on function public.create_proposal(uuid, uuid, uuid) to service_role;
grant execute on function public.confirm_proposal(uuid, bigint) to service_role;
grant execute on function public.decline_proposal(uuid, bigint) to service_role;
grant execute on function public.expire_pending_proposals() to service_role;
grant execute on function public.cancel_appointment(uuid, bigint, text) to service_role;

grant select on public.patient_absence_summary to authenticated, service_role;
revoke all on public.patient_absence_summary from anon;

commit;
