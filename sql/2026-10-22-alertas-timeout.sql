-- Alertas por e-mail: tempo de espera do pg_net (22/10/2026).
-- O envio SMTP (Gmail) leva mais de 5 s; o pg_net desistia em 5 s (padrão) e a execução da Edge Function
-- podia ser interrompida antes de enviar (aconteceu com o 1º aviso de cadastro de motorista).
-- Agora gatilhos e cron esperam até 60 s. O cron de 15 min também reenvia avisos de cadastro pendentes
-- (código na Edge Function alerta-checklist, modo "pendentes").

create or replace function frota.tg_checklist_alerta() returns trigger
language plpgsql security definer set search_path = frota as $$
begin
  if new.status = 'enviado' and old.status is distinct from 'enviado' and new.qtd_anomalias_novas > 0 then
    begin
      perform net.http_post(
        url := 'https://efmpzjkqiwyuumaoumof.supabase.co/functions/v1/alerta-checklist',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-automation-key', (select decrypted_secret from vault.decrypted_secrets where name = 'automation_secret_checklist')),
        body := jsonb_build_object('modo', 'checklist', 'checklist_id', new.id),
        timeout_milliseconds := 60000);
    exception when others then
      raise warning 'alerta-checklist não disparado para %: %', new.id, sqlerrm;
    end;
  end if;
  return new;
end $$;

create or replace function frota.tg_cadastro_motorista_alerta() returns trigger
language plpgsql security definer set search_path = frota as $$
begin
  begin
    perform net.http_post(
      url := 'https://efmpzjkqiwyuumaoumof.supabase.co/functions/v1/alerta-checklist',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-automation-key', (select decrypted_secret from vault.decrypted_secrets where name = 'automation_secret_checklist')),
      body := jsonb_build_object('modo', 'cadastro', 'cadastro_id', new.id),
      timeout_milliseconds := 60000);
  exception when others then
    raise warning 'alerta de cadastro não disparado para %: %', new.id, sqlerrm;
  end;
  return new;
end $$;

-- mesmo nome = atualiza o job existente
select cron.schedule('alerta-checklist-pendentes', '*/15 * * * *', $cron$
  select net.http_post(
    url := 'https://efmpzjkqiwyuumaoumof.supabase.co/functions/v1/alerta-checklist',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-automation-key', (select decrypted_secret from vault.decrypted_secrets where name = 'automation_secret_checklist')),
    body := jsonb_build_object('modo', 'pendentes'),
    timeout_milliseconds := 120000);
$cron$);

-- avisos de cadastro sem envio (ou com erro) nas últimas 48 h, com mais de 5 min — para o cron reenviar
create or replace function frota.listar_avisos_cadastro_pendentes() returns setof uuid
language sql stable security invoker set search_path = frota as $$
  select id from motoristas_cadastros
   where coalesce(alerta_status, 'erro') = 'erro'
     and criado_em > now() - interval '48 hours' and criado_em < now() - interval '5 minutes'
   order by criado_em
$$;
revoke all on function frota.listar_avisos_cadastro_pendentes() from public, anon, authenticated;
grant execute on function frota.listar_avisos_cadastro_pendentes() to service_role;
