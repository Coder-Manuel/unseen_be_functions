-- payments.provider: text -> public.payment_provider enum.
--
-- status and type are already enums; provider was the odd one out, so a typo
-- ('intansend') was a valid value. Re-runnable: it returns early once the
-- column is already the enum.
--
-- Adding a provider later is one statement, in its own migration (a new label
-- cannot be used in the transaction that adds it):
--   alter type public.payment_provider add value if not exists 'stripe';

do $$
begin
  if not exists (select 1 from pg_type where typname = 'payment_provider') then
    create type public.payment_provider as enum ('mpesa', 'intasend');
  end if;
end $$;

do $$
declare
  col_type oid;
  unexpected text;
  missing text;
  blocking text;
  old_default text;
  v record;
  captured jsonb := '[]'::jsonb;
  item jsonb;
begin
  select atttypid into col_type
  from pg_attribute
  where attrelid = 'public.payments'::regclass
    and attname = 'provider' and not attisdropped;

  if col_type is null then
    raise exception 'public.payments has no provider column';
  end if;
  if col_type = 'public.payment_provider'::regtype then
    return; -- already converted
  end if;

  -- 1. Every label the data uses must exist, or the cast fails halfway.
  select string_agg(quote_literal(label), ', ')
    into missing
  from (
    select distinct provider::text as label
    from public.payments
    where provider is not null
      and provider::text not in (
        select enumlabel from pg_enum
        where enumtypid = 'public.payment_provider'::regtype
      )
  ) s;

  if missing is not null then
    raise exception
      'payments.provider holds values missing from payment_provider: %. '
      'Fix the rows or add the labels in their own migration first.', missing;
  end if;

  -- 2. Policies referencing the column block the type change. Dropping and
  --    recreating them automatically is a security risk, so stop instead.
  select string_agg(polname, ', ') into blocking
  from pg_policy
  where polrelid = 'public.payments'::regclass
    and (
      coalesce(pg_get_expr(polqual, polrelid), '') like '%provider%'
      or coalesce(pg_get_expr(polwithcheck, polrelid), '') like '%provider%'
    );

  if blocking is not null then
    raise exception
      'These RLS policies on payments reference provider: %. '
      'Drop and recreate them around this migration by hand.', blocking;
  end if;

  -- 3. Capture every view that depends on payments, directly or through
  --    another view, with its options and grants, so it can be rebuilt.
  for v in
    with recursive deps as (
      select 'public.payments'::regclass as oid, 0 as depth
      union all
      select c.oid, d.depth + 1
      from deps d
      join pg_depend dep
        on dep.refobjid = d.oid and dep.classid = 'pg_rewrite'::regclass
      join pg_rewrite r on r.oid = dep.objid
      join pg_class c
        on c.oid = r.ev_class and c.oid <> d.oid and c.relkind in ('v', 'm')
      where d.depth < 10
    )
    select
      c.oid::regclass::text as name,
      c.relkind              as kind,
      max(d.depth)           as depth,
      pg_get_viewdef(c.oid, true) as def,
      array_to_string(c.reloptions, ', ') as opts,
      (
        select coalesce(
          string_agg(
            format('grant %s on %s to %s;', a.privilege_type,
                   c.oid::regclass::text,
                   case when a.grantee = 0 then 'public'
                        else quote_ident(a.grantee::regrole::text) end),
            ' '
          ), ''
        )
        from aclexplode(c.relacl) a
      ) as grants
    from deps d
    join pg_class c on c.oid = d.oid
    where d.depth > 0
    group by c.oid, c.relkind, c.relacl
    order by max(d.depth) desc
  loop
    captured := captured || jsonb_build_object(
      'name', v.name, 'kind', v.kind, 'depth', v.depth,
      'def', v.def, 'opts', v.opts, 'grants', v.grants
    );
    execute format(
      'drop %s %s',
      case when v.kind = 'm' then 'materialized view' else 'view' end,
      v.name
    );
    raise notice 'dropped dependent view % (rebuilt below)', v.name;
  end loop;

  -- 4. Convert the column, preserving any default.
  select pg_get_expr(ad.adbin, ad.adrelid) into old_default
  from pg_attrdef ad
  join pg_attribute a
    on a.attrelid = ad.adrelid and a.attnum = ad.adnum
  where ad.adrelid = 'public.payments'::regclass and a.attname = 'provider';

  alter table public.payments alter column provider drop default;
  alter table public.payments
    alter column provider type public.payment_provider
    using provider::text::public.payment_provider;

  if old_default is not null then
    execute format(
      'alter table public.payments alter column provider set default %L::public.payment_provider',
      trim(both '''' from split_part(old_default, '::', 1))
    );
  end if;

  -- 5. Rebuild the views, shallowest first.
  for item in
    select value from jsonb_array_elements(captured)
    order by (value ->> 'depth')::int asc
  loop
    execute format(
      'create %s %s %s as %s',
      case when item ->> 'kind' = 'm' then 'materialized view' else 'view' end,
      item ->> 'name',
      case when coalesce(item ->> 'opts', '') = '' then ''
           else format('with (%s)', item ->> 'opts') end,
      item ->> 'def'
    );
    if coalesce(item ->> 'grants', '') <> '' then
      execute item ->> 'grants';
    end if;
    raise notice 'rebuilt dependent view %', item ->> 'name';
  end loop;
end $$;
