begin;

-- A verified household owner can open the existing child session contract
-- without reading, decrypting or submitting the child's login code.
create function api.poortenboek_parent_open(
  _actor uuid,
  _event_slug text,
  _child_id uuid,
  _token_hash text,
  _previous_token_hash text default null,
  _digest text default null,
  _ciphertext text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  credential jsonb;
  code app_private.poortenboek_codes;
  session app_private.poortenboek_sessions;
begin
  if _token_hash is null or _token_hash !~ '^[a-f0-9]{64}$'
    or (_previous_token_hash is not null and _previous_token_hash !~ '^[a-f0-9]{64}$')
    or _token_hash = _previous_token_hash then
    raise exception 'INVALID_INPUT';
  end if;

  -- Reuse the authoritative owner/participation checks, event lock, child
  -- credential lock and collision-safe lazy provisioning. Never renew a code.
  credential := api.poortenboek_parent(
    _actor, _event_slug, 'view', _child_id, _digest, _ciphertext
  );
  if coalesce((credential->>'needsCode')::boolean, false) then
    return credential;
  end if;
  select * into strict code from app_private.poortenboek_codes
    where event_id = (credential->>'eventId')::uuid
      and child_id = _child_id and revoked_at is null;

  insert into app_private.poortenboek_sessions(code_id, token_hash)
    values (code.id, _token_hash) returning * into session;
  -- Possession of the previous browser token permits closing only that
  -- session. Other devices, and the separate adult Auth session, stay intact.
  update app_private.poortenboek_sessions set revoked_at = now()
    where token_hash = _previous_token_hash and revoked_at is null;
  update app_private.poortenboek_codes set last_used_at = date_trunc('minute', now())
    where id = code.id;
  insert into app_private.audit_events(
    event_id, actor_id, action, resource_type, resource_id, minimal_change
  ) values (code.event_id, _actor, 'poortenboek.parent_login', 'child', _child_id, '{}');
  return jsonb_build_object('ok', true, 'expiresAt', session.expires_at);
end $$;

revoke all on function api.poortenboek_parent_open(uuid,text,uuid,text,text,text,text)
  from public, anon, authenticated;
grant execute on function api.poortenboek_parent_open(uuid,text,uuid,text,text,text,text)
  to service_role;

commit;
